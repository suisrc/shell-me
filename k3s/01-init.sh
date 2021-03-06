#!/bin/sh

# rancher k3s专用脚本
# 集群入口使用nginx-ingress替换traefik
# 
set -e
NGINX_INGRESS_REPO=https://github.com/suisrc/k8s-nginx-ingress
NGINX_INGRESS_SVC=https://raw.githubusercontent.com/suisrc/k8s-nginx-ingress/master/25-service-metallb.yaml
DASHBOARD_SHELL=https://raw.githubusercontent.com/suisrc/shell-me/master/k3s/02-dash.sh

CALICO_REPO=https://docs.projectcalico.org/master/manifests/calico.yaml

# WireGuard + Kilo
KILO_WG0=https://raw.githubusercontent.com/squat/modulus/master/wireguard/daemonset.yaml
KILO_REPO=https://raw.githubusercontent.com/squat/kilo/master/manifests/kilo-k3s.yaml
KILO_REPO_FLANNEL=https://raw.githubusercontent.com/squat/kilo/master/manifests/kilo-typhoon-flannel.yaml

read -p "set hostname            ? [y/n] :" READ_IS_HOSTNAME
case ${READ_IS_HOSTNAME} in
    [yY][eE][sS]|[yY])
        read -p "hostname:" READ_HOSTNAME
        hostnamectl set-hostname ${READ_IS_HOSTNAME}
        echo ""                             >> /etc/hosts
        echo "127.0.0.1       $(hostname)"  >> /etc/hosts
    ;;
esac

read -p "set ipv4 forward        ? [y/n] :" READ_IS_FORWARD
case ${READ_IS_FORWARD} in
    # ipv4转发
    [yY][eE][sS]|[yY])
        cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
        setenforce 0
        sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
        sysctl --system
        #setenforce 1
        #sed -i "s/^SELINUX=disabled/SELINUX=enforcing/g" /etc/selinux/config
        ;;
esac

# 国内的vps， 使用dockerhub.azk8s.cn下载docker.io上的镜像
read -p "use dockerhub.azk8s.cn  ? [y/n] :" READ_IS_CHINESE
case ${READ_IS_CHINESE} in
    [yY][eE][sS]|[yY])
        mkdir -p /etc/rancher/k3s
        cat << EOF >/etc/rancher/k3s/registries.yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://dockerhub.azk8s.cn"
EOF
        ;;
esac

# 安装依赖
read -p "install dependent softs ? [y/n] :" READ_IS_INSTALL_SOFTS
case ${READ_IS_INSTALL_SOFTS} in
    [yY][eE][sS]|[yY])
        #yum install -y epel-release
        yum install -y container-selinux selinux-policy-base iptables runc git
        rpm -i https://rpm.rancher.io/k3s-selinux-0.1.1-rc1.el7.noarch.rpm
        ;;
esac
read -p "install wireguard 3.10  ? [y/n] :" READ_IS_INSTALL_WG
case ${READ_IS_INSTALL_WG} in
    [yY][eE][sS]|[yY])
        #rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
        #rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm
        #curl -sSLo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
        #yum install -y kmod-wireguard wireguard-tools kernel-devel
        # 这里只对3.10内核的linux做了验证
        # https://centos.pkgs.org/7/rpmfusion-free-updates-x86_64/kmod-wireguard-3.10.0-1062.el7.x86_64-0.0.20191219-1.el7.x86_64.rpm.html
        rpm -i  https://download1.rpmfusion.org/free/el/updates/7/x86_64/w/wireguard-0.0.20191219-2.el7.x86_64.rpm \
                https://download1.rpmfusion.org/free/el/updates/7/x86_64/k/kmod-wireguard-3.10.0-1062.el7.x86_64-0.0.20191219-1.el7.x86_64.rpm
        yum install -y kernel-devel
        ;;
esac

# 安装k3s
read -p "working for server      ? [y/n] :" READ_IS_SERVER
case ${READ_IS_SERVER} in
    [yY][eE][sS]|[yY])
        # defualt sqlite : /var/lib/rancher/k3s/server/db/state.db?_journal=WAL&cache=shared
        # read -p "datastore endpoint? :"  K3S_DATASTORE_ENDPOINT
        # read -p "node external ip  ? :"  
        # read -p "K3S_NODE_NAME     ? :"  K3S_NODE_NAME
        # https://github.com/squat/kilo/issues/11
        # k3s now needs the --node-ip flag because of a recent PR: https://github.com/rancher/k3s/pull/676.
        # read -p "node ip                 ? :" K3S_NODE_IP
        read -p "api server port(6443)   ? :" K3S_APISERVER_PORT
        read -p "k3s args                ? :" COMMOND_ARGS
        if [ ! ${K3S_APISERVER_PORT} ]; then
            K3S_APISERVER_PORT=6443
        fi
        read -p "network for server      ? [none/vxlan(default)/ipsec/host-gw/wireguard/calico/kilo/kilo2] :" K3S_SERVER_NETWORK
        if [ ! ${K3S_SERVER_NETWORK} ]; then
             K3S_SERVER_NETWORK=vxlan
        fi
        case ${K3S_SERVER_NETWORK} in
            calico)
                curl -sfL https://get.k3s.io | sh -s - server \
                  --flannel-backend none \
                  --no-deploy traefik \
                  --https-listen-port ${K3S_APISERVER_PORT} ${COMMOND_ARGS}
                echo "install network... sleep 30"
                sleep 30
                # 处理网络, 由于封闭网络对延迟特别敏感，我们这里使用跨互联网部署方式，所以必须使用非封闭网络
                # https://rancher.com/docs/rancher/v2.x/en/faq/networking/cni-providers/
                # kubectl apply -f https://docs.projectcalico.org/master/manifests/calico.yaml
                # 参照《Calico CNI插件指南》，修改Calico YAML，以便在container_settings部分中允许IP转发
                # cat /etc/cni/net.d/10-calico.conflist
                curl -sSL ${CALICO_REPO} | \
                sed "s/\"ipam\":/\"container_settings\": {\n              \"allow_ip_forwarding\": true\n          },\n          &/g" | \
                kubectl apply -f -
                # sed "s%192.168.0.0/16%10.42.0.0/16%" | \
                # kubectl edit ConfigMap calico-config -n kube-system
            ;;
            kilo)
                # Kilo is a multi-cloud network overlay built on WireGuard and designed for Kubernetes.
                curl -sfL https://get.k3s.io | sh -s - server \
                  --no-deploy traefik \
                  --flannel-backend none \
                  --https-listen-port ${K3S_APISERVER_PORT} ${COMMOND_ARGS}
                echo "install network... sleep 30"
                sleep 30
                # https://github.com/squat/kilo/issues/11
                # Step 1: install WireGuard
                # curl -sSL ${KILO_WG0} | sed "s/k8s.gcr.io\/pause-amd64/rancher\/pause-amd64/g" | kubectl apply -f -
                # Step 2: open WireGuard port
                # Kilo uses UDP port 51820.
                # Step 3: specify topology
                # for node in $(kubectl get nodes | grep -i gcp | awk '{print $1}'); do kubectl annotate node $node kilo.squat.ai/location="gcp"; done
                # ali, tx, hw, gcp, aws, azure, home, pacificrack..., master节点被单独标记
                kubectl annotate node $(hostname) kilo.squat.ai/location="master-00"
                # Step 4: ensure nodes have public IP
                # https://github.com/squat/kilo/blob/master/docs/annotations.md#force-endpoint
                # https://kilo.squat.ai/docs/annotations
                #kubectl annotate node $(hostname) kilo.squat.ai/force-endpoint="$(hostname):51820"
                #kubectl annotate node $(hostname) kilo.squat.ai/force-internal-ip="$(hostname)/32"
                #kubectl annotate node $(hostname) kilo.squat.ai/leader="true"
                # Step 5: install Kilo!
                # KILO_REPO=https://raw.githubusercontent.com/squat/kilo/master/manifests/kilo-k3s.yaml
                curl -sSL ${KILO_REPO} | kubectl apply -f -
                # https://github.com/squat/kilo
                # 需要注意kilo有2种安装方式，一种是纯kilo方式，一种是与flannel嵌入使用
                # kilo.squat.ai/location和kilo.squat.ai/force-endpoint需要对每一个节点进行标记
            ;;
            kilo2)
                curl -sfL https://get.k3s.io | sh -s - server \
                  --no-deploy traefik \
                  --https-listen-port ${K3S_APISERVER_PORT} ${COMMOND_ARGS}
                echo "install network... sleep 30s"
                sleep 30
                kubectl annotate node $(hostname) kilo.squat.ai/location="master-00"
                # KILO_REPO_FLANNEL=https://raw.githubusercontent.com/squat/kilo/master/manifests/kilo-typhoon-flannel.yaml
                curl -sSL ${KILO_REPO_FLANNEL} | kubectl apply -f -
            ;;
            none|vxlan|ipsec|host-gw|wireguard)
                curl -sfL https://get.k3s.io | sh -s - server \
                  --flannel-backend ${K3S_SERVER_NETWORK} \
                  --no-deploy traefik \
                  --https-listen-port ${K3S_APISERVER_PORT} ${COMMOND_ARGS}
            ;;
            *)
                echo "error: unable to process network options [${K3S_SERVER_NETWORK}]"
            ;;
        esac
        # 安装nginx
        kubectl apply -k ${NGINX_INGRESS_REPO}
        kubectl apply -f ${NGINX_INGRESS_SVC}
        # 安装dashboard
        #read -p "kubernetes dashboard      ? [y/n] :" READ_IS_DASHBOARD
        #case ${READ_IS_DASHBOARD} in
        #    [yY][eE][sS]|[yY])
        #        curl -sSL ${DASHBOARD_SHELL} | source -
        #esac
        # 监控所有组件安装完成
        watch kubectl get pods -A -o wide
        echo "K3S_URL  : https://$(hostname):${K3S_APISERVER_PORT}"
        echo "K3S_TOKEN: $(cat /var/lib/rancher/k3s/server/node-token)"
        # sh /usr/local/bin/k3s-uninstall.sh
        ;;
    *)
        # read -p "node external ip          ? :" K3S_NODE_EXTERNAL_IP
        read -p "server endpoint           ? :" K3S_URL
        read -p "server token              ? :" K3S_TOKEN
        # read -p "K3S_NODE_NAME  ? :" K3S_NODE_NAME
        curl -sfL https://get.k3s.io | sh -s - agent \
            --server ${K3S_URL} \
            --token  ${K3S_TOKEN}
        # --node-external-ip=$K3S_NODE_EXTERNAL_IP
        # cat /etc/systemd/system/k3s-agent.service
        # systemctl status k3s-agent
        # sh /usr/local/bin/k3s-agent-uninstall.sh
        ;;
esac

# 解除master节点无法安装软件
# kubectl taint nodes --all node-role.kubernetes.io/master-
# error: a container name must be specified for pod svclb-ingress-nginx-svc-lcb88, choose one of: [lb-port-80 lb-port-443]
#
# kubectl edit pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx
# kubectl logs pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx -c lb-port-80
# kubectl describe deployment nginx-ingress-app -n ingress-nginx
# kubectl describe deployment  metrics-server -n kube-system
# kubectl describe pod nginx-ingress-app-66896c7d7c-djxt7 -n ingress-nginx
#
# kubectl describe pod kilo -n kube-system
# kubectl logs kilo-lz799 -n kube-system -c install-cni
# kubectl logs metrics-server-6d684c7b5-z86l2 -n kube-system -c modulus
# kubectl get nodes --show-labels
#

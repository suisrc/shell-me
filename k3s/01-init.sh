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

read -p "set hostname ? [y/n] :" READ_IS_HOSTNAME
case $READ_IS_HOSTNAME in
    [yY][eE][sS]|[yY])
        read -p "hostname:" READ_HOSTNAME
        hostnamectl set-hostname $READ_IS_HOSTNAME
        echo ""                             >> /etc/hosts
        echo "127.0.0.1       $(hostname)"  >> /etc/hosts
    ;;
esac

# ipv4转发
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 国内的vps， 使用dockerhub.azk8s.cn下载docker.io上的镜像
read -p "use dockerhub.azk8s.cn?[y/n] :" READ_IS_CHINESE
case $READ_IS_CHINESE in
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
read -p "install selinux ... softs ?[y/n] :" READ_IS_INSTALL_SOFTS
case $READ_IS_INSTALL_SOFTS in
    [yY][eE][sS]|[yY])
        yum install -y container-selinux selinux-policy-base iptables runc git
        rpm -i https://rpm.rancher.io/k3s-selinux-0.1.1-rc1.el7.noarch.rpm
        ;;
esac

#setenforce 0
#sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
#setenforce 1
#sed -i "s/^SELINUX=disabled/SELINUX=enforcing/g" /etc/selinux/config

# 安装k3s
read -p "working for server?[y/n] :" READ_IS_SERVER
case $READ_IS_SERVER in
    [yY][eE][sS]|[yY])
        # defualt sqlite : /var/lib/rancher/k3s/server/db/state.db?_journal=WAL&cache=shared
        # read -p "datastore endpoint? :"  K3S_DATASTORE_ENDPOINT
        # read -p "node external ip  ? :"  
        # read -p "K3S_NODE_NAME     ? :"  K3S_NODE_NAME
        # https://github.com/squat/kilo/issues/11
        # k3s now needs the --node-ip flag because of a recent PR: https://github.com/rancher/k3s/pull/676.
        # read -p "node ip           ? :" K3S_NODE_IP
        read -p "api server port(6443) ? :" K3S_APISERVER_PORT
        if [ ! $K3S_APISERVER_PORT ]; then
            K3S_APISERVER_PORT=6443
        fi
        read -p "network for server?[none/vxlan(default)/ipsec/host-gw/wireguard/calico/kilo] :" K3S_SERVER_NETWORK
        if [ ! $K3S_SERVER_NETWORK ]; then
             curl -sfL https://get.k3s.io | sh -s - server \
               --no-deploy traefik \
               --https-listen-port $K3S_APISERVER_PORT
        else
            case $K3S_SERVER_NETWORK in
                calico)
                    curl -sfL https://get.k3s.io | sh -s - server \
                      --flannel-backend=none \
                      --no-deploy traefik \
                      --https-listen-port $K3S_APISERVER_PORT
                    # 处理网络, 由于封闭网络对延迟特别敏感，我们这里使用跨互联网部署方式，所以必须使用非封闭网络
                    # https://rancher.com/docs/rancher/v2.x/en/faq/networking/cni-providers/
                    # kubectl apply -f https://docs.projectcalico.org/master/manifests/calico.yaml
                    # 参照《Calico CNI插件指南》，修改Calico YAML，以便在container_settings部分中允许IP转发
                    # cat /etc/cni/net.d/10-calico.conflist
                    curl -sSL $CALICO_REPO | \
                    sed "s/\"ipam\":/\"container_settings\": {\n              \"allow_ip_forwarding\": true\n          },\n          &/g" | \
                    kubectl apply -f -
                    # sed "s%192.168.0.0/16%10.42.0.0/16%" | \
                    # kubectl edit ConfigMap calico-config -n kube-system
                ;;
                kilo)
                    # Kilo is a multi-cloud network overlay built on WireGuard and designed for Kubernetes.
                    curl -sfL https://get.k3s.io | sh -s - server \
                      --flannel-backend=none \
                      --no-deploy traefik \
                      --https-listen-port $K3S_APISERVER_PORT
                    # Step 1: install WireGuard
                    kubectl apply -f $KILO_WG0
                    # Step 2: open WireGuard port
                    # Kilo uses UDP port 51820.
                    # Step 3: specify topology
                    # for node in $(kubectl get nodes | grep -i gcp | awk '{print $1}'); do kubectl annotate node $node kilo.squat.ai/location="gcp"; done
                    # ali, tx, hw, gcp, aws, azure, home, pacificrack..., master节点被单独标记
                    kubectl annotate node $(hostname) kilo.squat.ai/location="master-00"
                    # Step 4: ensure nodes have public IP
                    # https://github.com/squat/kilo/blob/master/docs/annotations.md#force-endpoint
                    kubectl annotate node $(hostname) kilo.squat.ai/force-endpoint="$(hostname):51820"
                    # Step 5: install Kilo!
                    curl -sSL $KILO_REPO | kubectl apply -f -
                    # https://github.com/squat/kilo
                    # 需要注意kilo有2种安装方式，一种是纯kilo方式，一种是与flannel嵌入使用
                    # kilo.squat.ai/location和kilo.squat.ai/force-endpoint需要对每一个节点进行标记
                ;;
                none/vxlan/ipsec/host-gw/wireguard)
                    curl -sfL https://get.k3s.io | sh -s - server \
                      --flannel-backend=$K3S_SERVER_NETWORK \
                      --no-deploy traefik \
                      --https-listen-port $K3S_APISERVER_PORT
                ;;
                *)
                    echo "error: unable to process network options [$K3S_SERVER_NETWORK]"
                ;;
            esac
        fi
        # sh /usr/local/bin/k3s-uninstall.sh
        # 安装nginx
        kubectl apply -k $NGINX_INGRESS_REPO
        kubectl apply -f $NGINX_INGRESS_SVC
        # 安装dashboard
        read -p "install kubernetes dashboard?[y/n] :" READ_IS_DASHBOARD
        case $READ_IS_DASHBOARD in
            [yY][eE][sS]|[yY])
                curl -sSL $DASHBOARD_SHELL | sh -
        esac
        # rm -f dashboard-irs.yaml
        # 监控所有组件安装完成
        watch kubectl get pods -A -o wide
        echo "K3S_URL  : https://$(hostname):$K3S_APISERVER_PORT"
        echo "K3S_TOKEN: $(cat /var/lib/rancher/k3s/server/node-token)"
        ;;
    *)
        read -p "node external ip  ? :" K3S_NODE_EXTERNAL_IP
        read -p "server endpoint   ? :" K3S_URL
        read -p "server token      ? :" K3S_TOKEN
        # read -p "K3S_NODE_NAME  ? :" K3S_NODE_NAME
        curl -sfL https://get.k3s.io | sh -s - agent \
            --server $K3S_URL \
            --token  $K3S_TOKEN
        # --node-external-ip=$K3S_NODE_EXTERNAL_IP
        # cat /etc/systemd/system/k3s-agent.service
        # systemctl status k3s-agent
        # sh /usr/local/bin/k3s-agent-uninstall.sh
        ;;
esac

# 解除master节点无法安装软件
# kubectl taint nodes --all node-role.kubernetes.io/master-
# error: a container name must be specified for pod svclb-ingress-nginx-svc-lcb88, choose one of: [lb-port-80 lb-port-443]
# kubectl edit pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx
# kubectl logs pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx -c lb-port-80
# kubectl logs pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx -c lb-port-443
#
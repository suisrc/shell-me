#!/bin/sh

# 初始化hostname
# rancher k3s专用脚本
# 注意apiserver端口从6443变更为33333
# 
set -e
NGINX_INGRESS_REPO=https://github.com/suisrc/k8s-nginx-ingress
NGINX_INGRESS_SVC=https://raw.githubusercontent.com/suisrc/k8s-nginx-ingress/master/25-service-metallb.yaml
CALICO_REPO=https://docs.projectcalico.org/master/manifests/calico.yaml
DASHBOARD_REPO=https://github.com/kubernetes/dashboard/releases

read -p "set hostname ? [y/n] :" READ_IS_HOSTNAME
case $READ_IS_HOSTNAME in
    [yY][eE][sS]|[yY])
        read -p "hostname:" READ_HOSTNAME
        hostnamectl set-hostname $READ_HOSTNAME
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
yum install -y container-selinux selinux-policy-base iptables runc git
rpm -i https://rpm.rancher.io/k3s-selinux-0.1.1-rc1.el7.noarch.rpm

#setenforce 0
#sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
#setenforce 1
#sed -i "s/^SELINUX=disabled/SELINUX=enforcing/g" /etc/selinux/config

# 安装k3s
read -p "Working by server?[y/n] :" READ_IS_SERVER
case $READ_IS_SERVER in
    [yY][eE][sS]|[yY])
        # defualt sqlite : /var/lib/rancher/k3s/server/db/state.db?_journal=WAL&cache=shared
        # read -p "datastore endpoint? :"  K3S_DATASTORE_ENDPOINT
        read -p "node external ip  ? :"  
        read -p "K3S_NODE_NAME     ? :"  K3S_NODE_NAME
        curl -sfL https://get.k3s.io | sh -s - server \
            --flannel-backend=none \
            --no-deploy traefik \
            --https-listen-port 33333
        # sh /usr/local/bin/k3s-uninstall.sh
        # 解除master节点无法安装软件
        # kubectl taint nodes --all node-role.kubernetes.io/master-
        # 安装网卡
        # 处理网络, 由于封闭网络对延迟特别敏感，我们这里使用跨互联网部署方式，所以必须使用非封闭网络
        # https://rancher.com/docs/rancher/v2.x/en/faq/networking/cni-providers/
        # kubectl apply -f https://docs.projectcalico.org/master/manifests/calico.yaml
        # 参照《Calico CNI插件指南》，修改Calico YAML，以便在container_settings部分中允许IP转发
        # cat /etc/cni/net.d/10-calico.conflist
        curl -sSL $CALICO_REPO | \
        sed "s/\"ipam\":/\"container_settings\": {\n              \"allow_ip_forwarding\": true\n          },\n          &/g" | \
        kubectl apply -f -
        #sed "s%192.168.0.0/16%10.42.0.0/16%" | \
        # kubectl edit ConfigMap calico-config -n kube-system
        # 安装nginx
        kubectl apply -k $NGINX_INGRESS_REPO
        kubectl apply -f $NGINX_INGRESS_SVC
        # 安装dashboard
        VERSION_KUBE_DASHBOARD=$(curl -w '%{url_effective}' -I -L -s -S ${DASHBOARD_REPO}/latest -o /dev/null | sed -e 's|.*/||')
        echo "dashboard， version: ${VERSION_KUBE_DASHBOARD}"
        kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/${VERSION_KUBE_DASHBOARD}/aio/deploy/recommended.yaml
        # 输入dashboard使用的域名
        read -p "dashboard url ? :" DASHBOARD_URL
        read -p "dashboard user? :" DASHBOARD_USR
        cat <<EOF >dashboard-irs.yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: dashboard-l2-irs
  annotations:
    kubernetes.io/ingress.class: nginx
    #nginx.ingress.kubernetes.io/ssl-passthrough: 'true'
    nginx.ingress.kubernetes.io/backend-protocol: 'HTTPS'
  namespace: kubernetes-dashboard
spec:
  rules:
    - host: ${DASHBOARD_URL}
      http:
        paths:
        - backend:
            serviceName: kubernetes-dashboard
            servicePort: 443
          path: /
  tls:
    - hosts:
        - ${DASHBOARD_URL}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${DASHBOARD_USR}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: ${DASHBOARD_USR}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${DASHBOARD_USR}
  namespace: kube-system
EOF
        kubectl apply -f dashboard-irs.yaml
        echo "user: ${DASHBOARD_USR}, token======================================================="
        kubectl -n kubernetes-dashboard describe secret $DASHBOARD_USR -n kube-system | grep ^token
        # rm -f dashboard-irs.yaml
        # 监控所有组件安装完成
        watch kubectl get pods -A -o wide
        ;;
    *)
        read -p "server endpoint? :" K3S_URL
        read -p "server token   ? :" K3S_TOKEN
        read -p "K3S_NODE_NAME  ? :" K3S_NODE_NAME
        curl -sfL https://get.k3s.io | sh -s - agent
        # sh /usr/local/bin/k3s-agent-uninstall.sh
        ;;
esac

# error: a container name must be specified for pod svclb-ingress-nginx-svc-lcb88, choose one of: [lb-port-80 lb-port-443]
# kubectl edit pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx
# kubectl logs pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx -c lb-port-80
# kubectl logs pod/svclb-ingress-nginx-svc-lcb88 -n ingress-nginx -c lb-port-443

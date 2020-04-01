# 初始化hostname
# rancher k3s专用脚本
# 注意apiserver端口从6443变更为33333
# 
NGINX_INGRESS_REPO=https://raw.githubusercontent.com/suisrc/k8s-nginx-ingress/master
CALICO_REPO=https://docs.projectcalico.org/master/manifests/calico.yaml

read -p "hostname:" READ_HOSTNAME
hostnamectl set-hostname $READ_HOSTNAME

echo "127.0.0.1       $(hostname)"  >> /etc/hosts

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
            --https-listen-port 33333 \
            --cluster-init

        # 解除master节点无法安装软件
        kubectl taint nodes --all node-role.kubernetes.io/master-
        # 安装网卡
        # 处理网络, 由于封闭网络对延迟特别敏感，我们这里使用跨互联网部署方式，所以必须使用非封闭网络
        # https://rancher.com/docs/rancher/v2.x/en/faq/networking/cni-providers/
        # kubectl apply -f https://docs.projectcalico.org/master/manifests/calico.yaml
        # 参照《Calico CNI插件指南》，修改Calico YAML，以便在container_settings部分中允许IP转发
        curl -sSL $CALICO_REPO | \
        sed -i "s/\"plugins\":/\"container_settings\": {\n        \"allow_ip_forwarding\": true\n      },\n      &/g" | \
        kubectl apply -f -
        # 安装nginx
        kubectl apply -k $NGINX_INGRESS_REPO/kustomization.yaml
        kubectl apply -f $NGINX_INGRESS_REPO/25-service-metallb.yaml
        # 监控所有组件安装完成
        watch kubectl get pods -A -o wide
        ;;
    *)
        read -p "server endpoint? :" K3S_URL
        read -p "server token   ? :" K3S_TOKEN
        read -p "K3S_NODE_NAME  ? :" K3S_NODE_NAME
        curl -sfL https://get.k3s.io | sh -s - agent
        ;;
esac


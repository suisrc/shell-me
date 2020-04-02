# 资源地址
DASHBOARD_REPO=https://github.com/kubernetes/dashboard/releases
DASHBOARD_REPO_RAW=https://raw.githubusercontent.com/kubernetes/dashboard
# 执行安装
VERSION_KUBE_DASHBOARD=$(curl -w '%{url_effective}' -I -L -s -S ${DASHBOARD_REPO}/latest -o /dev/null | sed -e 's|.*/||')
echo "dashboard， version: ${VERSION_KUBE_DASHBOARD}"
kubectl create -f ${DASHBOARD_REPO_RAW}/${VERSION_KUBE_DASHBOARD}/aio/deploy/recommended.yaml
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
# 暂时保留执行的内容
kubectl apply -f dashboard-irs.yaml #&& rm -f dashboard-irs.yaml
echo "url :   ${DASHBOARD_URL}"
echo "user:   ${DASHBOARD_USR}"
kubectl -n kubernetes-dashboard describe secret $DASHBOARD_USR -n kube-system | grep ^token

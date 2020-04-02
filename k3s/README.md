# 说明

用户快速部署rancher k3s环境
## 执行安装
```
# 管道在这里，会导致case in语句丢失，无法使用
curl -sfSL https://raw.githubusercontent.com/suisrc/shell-me/master/k3s/01-init.sh -o init.sh && sh init.sh && rm -f init.sh
curl -sfSL https://raw.githubusercontent.com/suisrc/shell-me/master/k3s/02-dash.sh -o dash.sh && sh dash.sh && rm -f dash.sh
```

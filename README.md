# RealityGo-Reality一键部署脚本

这是一个用于在 Linux 服务器上自动安装和配置 [Sing-Box](https://sing-box.sagernet.org/) 作为 Reality 代理服务器的 Bash 脚本。脚本会自动检测服务器信息，生成配置文件和分享链接，并设置 systemd (或 Alpine Linux 的 OpenRC) 服务。
## 安装


```
bash <(curl -sL 'https://raw.githubusercontent.com/Yeungchichao/RealityGo/main/RealityGo.sh')
```



## 卸载方法

## 卸载


```
bash <(curl -sL 'https://raw.githubusercontent.com/Yeungchichao/RealityGo/main/RealityGo0.sh')
```

rm -f /etc/systemd/system/xray@.service

systemctl daemon-reload

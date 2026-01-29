## 1. 使用GitHub在线脚本实现远程登录 

**⚠️ 重要安全警告：**

1. **开启 Root 远程登录**存在极高风险，建议配合防火墙使用。
2. **在服务端生成私钥**并下载（反向操作）不如“在本地生成公钥上传”安全，因为私钥曾存在于服务器上，且传输过程可能泄露。
3. 请确保脚本所在的 GitHub 仓库是**私有**的，或者脚本本身不包含敏感硬编码信息。

## 2. 组合在线GitHub脚本
```
直接在GitHub中编辑ssh_configure.sh中浏览器顶部获取 https://github.com/ATX8T/OpenSSH-OpenSSL/blob/main/ssh_configure.sh

  开始组合
源地址：https://github.com/ATX8T/OpenSSH-OpenSSL/blob/main/ssh_configure.sh
去掉源连接里面的 /blob 与 https://github.com
组合到：https://raw.githubusercontent.com 里面
https://raw.githubusercontent.com/ATX8T/OpenSSH-OpenSSL/main/ssh_configure.sh
```

## 3. 实现远程登录
- ⚠️ 需要注意服务器能不能连接到GitHub
- ⚠️ 登录执行前检查当前登录的用户是否有root权限
- ⚠️ 下载到本地使用 chmod +x 赋予权限


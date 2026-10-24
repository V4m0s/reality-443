# Windows 客户端：官方 Xray + 分流 + 开机自启

## 为什么不用现成的机场客户端

REALITY 的握手细节与内核版本强绑定。实测同一台 Xray 26 服务端：

| 客户端 | 结果 |
|---|---|
| Xray 官方 ≥ 26 | ✅ |
| mihomo 1.10（很多客户端自带） | ❌ `REALITY authentication failed` |
| mihomo 1.19（最新） | ❌ 同上或握手超时 |

原因是 Xray 26 的 REALITY 用了 ML-KEM 后量子密钥交换，mihomo 系还没跟上。
所以 Windows 上直接用**官方 Xray** 做本机代理：它体积小、无界面、开机自启后完全无感。

---

## 1. 下载与解压

从 [Xray-core Releases](https://github.com/XTLS/Xray-core/releases/latest) 下载
`Xray-windows-64.zip`，解压到：

```
C:\Users\<你>\vps-proxy\
    xray.exe
    geoip.dat
    geosite.dat
    config.json      ← 下一步创建
```

`geoip.dat` / `geosite.dat` 是分流规则库，必须和 `xray.exe` 放同一目录。

---

## 2. 写客户端配置

新建 `config.json`，把服务端脚本打印的三个值填进去：

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" } },
    { "tag": "http",  "port": 10809, "listen": "127.0.0.1", "protocol": "http",
      "settings": {} }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [{
        "address": "1.2.3.4",
        "port": 443,
        "users": [{ "id": "UUID", "encryption": "none", "flow": "xtls-rprx-vision" }]
      }]},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "www.microsoft.com",
          "fingerprint": "chrome",
          "publicKey": "PUBLIC_KEY",
          "shortId": "SHORT_ID",
          "spiderX": "/"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "proxy" }
    ]
  }
}
```

**三处必须逐字符一致，否则认证失败**：

| 字段 | 来源 |
|---|---|
| `address` | 你的 VPS 公网 IP（写 IP，不要写域名） |
| `id` | 服务端打印的 UUID |
| `publicKey` | 服务端打印的公钥（43 字符 base64url） |
| `shortId` | 服务端打印的 shortId（16 位 hex） |
| `serverName` | 必须等于服务端的 `serverNames[0]` |

---

## 3. 分流为什么这么写

```json
{ "domain": ["geosite:cn"], "outboundTag": "direct" }   // B站/微信/银行/游戏 → 直连
{ "ip":      ["geoip:cn"],  "outboundTag": "direct" }   // 国内 CDN 的 IP → 直连
{ "network": "tcp,udp",     "outboundTag": "proxy"  }   // 其余 → 东京
```

- `domainStrategy: IPIfNonMatch` 表示**先用本地 DNS 解析**，拿到的是运营商就近的 CDN IP，
  再判断归属。这样不会出现"代理 DNS 把国内站点解析到海外 → 视频卡成 PPT"。
- 结果是：**国内流量根本不出境**，只多花 1.5ms 的本地转发；只有墙外域名才走 VPS。

验证（同一台机器对比）：

```
华为云 60MB 文件   直连 2.02 MB/s   经代理 1.71 MB/s   ← 同一水平
baidu.com          0.29s            0.08s            ← 反而更快（连接复用）
```

---

## 4. 启动

```cmd
cd C:\Users\<你>\vps-proxy
xray.exe run -c config.json
```

窗口不要关（后面会做成开机自启、无窗口）。

---

## 5. 把系统代理指向它

**方式一：图形界面**

设置 → 网络和 Internet → 代理 → 手动设置代理：

```
地址: 127.0.0.1    端口: 10809
```

**方式二：命令行（推荐，可脚本化）**

```cmd
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /d 127.0.0.1:10809 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f
```

**方式三：环境变量（给命令行工具用）**

```cmd
setx HTTP_PROXY  http://127.0.0.1:10809
setx HTTPS_PROXY http://127.0.0.1:10809
setx NO_PROXY    localhost,127.0.0.1,::1,.deepseek.com,.volces.com,.modelscope.cn,.aliyuncs.com
```

> `NO_PROXY` 别省：国内 API 直连，且代理进程挂掉时这些调用不受影响。
>
> `setx` 只对新开的进程生效；已经开着的终端要重开。

---

## 6. 开机自启（无窗口）

**① 代理进程随系统启动**（SYSTEM 身份，登录前就跑）：

```cmd
schtasks /Create /F /TN VPS-Proxy /SC ONSTART /RU SYSTEM /RL HIGHEST ^
  /TR "\"C:\Users\<你>\vps-proxy\xray.exe\" run -c \"C:\Users\<你>\vps-proxy\config.json\""
schtasks /Run /TN VPS-Proxy
```

**② 系统代理随登录设置**（每用户注册表，所以每个账户各放一份）。

在 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` 新建 `VPS代理.vbs`：

```vbs
Set sh = CreateObject("WScript.Shell")
base = "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
sh.Run "reg add """ & base & """ /v ProxyServer /d 127.0.0.1:10809 /f", 0, True
sh.Run "reg add """ & base & """ /v ProxyEnable /t REG_DWORD /d 1 /f", 0, True
sh.Run "setx HTTP_PROXY http://127.0.0.1:10809", 0, True
sh.Run "setx HTTPS_PROXY http://127.0.0.1:10809", 0, True
```

这样开机后：**服务自动起 → 登录后代理自动开 → 用户什么都不用做**。

---

## 7. 验收

```powershell
# 走系统代理（不指定 -x，验证真正生效）
(Invoke-WebRequest https://www.google.com/generate_204 -UseBasicParsing).StatusCode   # 204
(Invoke-WebRequest https://api.ipify.org -UseBasicParsing).Content                    # 你的 VPS IP
(Invoke-WebRequest https://www.baidu.com -UseBasicParsing).StatusCode                 # 200
```

浏览器若仍异常：**完全退出浏览器再打开**（它启动时读一次代理设置，之后不会重读）。

---

## 8. 日常操作

| 要做的事 | 命令 |
|---|---|
| 看是否在跑 | `tasklist /FI "IMAGENAME eq xray.exe"` |
| 重启 | `schtasks /End /TN VPS-Proxy` 然后 `schtasks /Run /TN VPS-Proxy` |
| 改配置 | 编辑 `config.json` → 重启任务 |
| 看日志 | 把 `"loglevel"` 改成 `"info"` 后重启任务 |

---

下一篇：[04-客户端-移动端.md](04-移动端技术细节.md)

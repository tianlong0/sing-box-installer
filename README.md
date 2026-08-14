# sing-box 一键安装器（自研版）

基于官方 [sing-box](https://github.com/SagerNet/sing-box) 核心的**自研一键安装脚本**，参考了 fscarmen/sing-box 的交互思路，但完全重写：

- ✅ 官方直连下载 + **SHA256 校验**（杜绝第三方镜像投毒）
- ✅ 无后台回传 / 无统计
- ✅ 数据驱动：加协议只需改注册表，不再 5000 行 if
- ✅ 状态持久化到 state.env（告别 sed/awk 抠 JSON）
- ✅ 干净卸载

## 支持的协议

| 协议 | 传输 | 定位 |
|---|---|---|
| XTLS + Reality | TCP | 最安全最稳，主力 |
| Hysteria2 | UDP/QUIC | 最快，弱网加速 |
| Tuic V5 | UDP/QUIC | 高速备胎 |
| Shadowsocks 2022 | TCP/UDP | 老牌稳定 |
| Trojan | TCP | 经典 |

## 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tianlong0/sing-box-installer/main/install.sh)
```

或先下载再执行（推荐，便于审查）：

```bash
curl -fsSL https://raw.githubusercontent.com/tianlong0/sing-box-installer/main/install.sh -o install.sh
bash install.sh
```

## 用法

```bash
sb               # 交互菜单
sb install       # 一键安装（全部 5 协议）
sb show          # 查看节点 / 订阅链接
sb status        # 服务状态
sb restart       # 重启
sb upgrade       # 升级 sing-box 内核
sb uninstall     # 完全卸载
```

自定义参数（环境变量）：

```bash
PORT=8881 NAME=mysb SNI=www.microsoft.com PROTO="reality hysteria2" sb install
```

- `PORT`：起始端口（默认 8881，协议端口依次 +1）
- `NAME`：节点名
- `SNI`：reality 伪装域名（默认 www.microsoft.com，建议选你服务器可达的稳定大站）
- `PROTO`：要装的协议（空格分隔，默认全部）

## 目录结构

```
/etc/sing-box/
├── sing-box          # 内核二进制
├── conf/             # JSON 配置（00_base + 各协议 inbound）
├── cert/             # 自签证书
├── logs/
├── links.txt         # 订阅链接
├── state.env         # 状态（端口/UUID/密钥）
└── sb.sh            # 本脚本缓存
```

## 免责声明

仅供学习研究使用，请遵守所在国家/地区法律法规。使用者自行承担一切后果。

## License

MIT

#!/usr/bin/env bash
# ============================================================
#  sing-box 一键安装器 (自研 · 数据驱动 · 免第三方镜像)
#  协议: reality / hysteria2 / tuic / shadowsocks-2022 / trojan
#  特点: 官方直连下载 + SHA256 校验 + 无回传 + 干净卸载
# ============================================================
set -eo pipefail

VERSION="v1.0.0"
REPO_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DL_BASE="https://github.com/SagerNet/sing-box/releases/download"
SELF_URL="https://raw.githubusercontent.com/tianlong0/sing-box-installer/main/install.sh"
WORK_DIR="/etc/sing-box"
CONF_DIR="$WORK_DIR/conf"
CERT_DIR="$WORK_DIR/cert"
LOG_DIR="$WORK_DIR/logs"
STATE_FILE="$WORK_DIR/state.env"
BIN="$WORK_DIR/sing-box"
SERVICE_NAME="sing-box"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CMD_LINK="/usr/local/bin/sb"
TEMP_DIR=$(mktemp -d)

DEFAULT_PORT=8881
DEFAULT_SNI="www.microsoft.com"
DEFAULT_NODE="sb"

# 协议注册表（有序；端口=起始端口+序号）
ALL_PROTOCOLS="reality hysteria2 tuic shadowsocks trojan"

c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_nc='\033[0m'
info()  { printf "$c_green[+] %s$c_nc\n" "$*"; }
warn()  { printf "$c_yellow[!] %s$c_nc\n" "$*"; }
error() { printf "$c_red[-] %s$c_nc\n" "$*" >&2; }
die()   { error "$*"; exit 1; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    info "安装依赖 $1 ..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq "$2"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q "$2"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q "$2"
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "$2"
    else
      die "无法自动安装 $1，请手动安装后重试"
    fi
  fi
}

check_root() { [ "$(id -u)" = "0" ] || die "请以 root 运行: sudo -i 后重试"; }

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT INT TERM

detect_arch() {
  local m arch
  m=$(uname -m)
  case "$m" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv7" ;;
    *) die "不支持的架构: $m" ;;
  esac
  if [ -f /etc/alpine-release ] || (ldd --version 2>&1 | grep -qi musl); then
    arch="$arch-musl"
  fi
  ARCH="$arch"
}

detect_init() {
  if [ -f /etc/alpine-release ]; then INIT="openrc"; else INIT="systemd"; fi
}

fetch_release_info() {
  curl -fsSL --retry 3 --connect-timeout 10 "$REPO_API" || die "无法访问 GitHub API（网络问题？）"
}

parse_version() {
  printf '%s' "$1" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | sed 's/^v//'
}

asset_digest() {
  printf '%s' "$1" | sed 's/},{/}\n{/g' | awk -v n="$2" '
    BEGIN{w=0}
    /"name"/{ w = ($0 ~ "\"" n "\"") ? 1 : 0 }
    w && /"digest"/{
      if (match($0, /sha256:[0-9a-f]{64}/)) print substr($0,RSTART,RLENGTH)
      exit
    }
  '
}

download_singbox() {
  local json ver asset url digest actual
  info "查询 sing-box 最新版本 ..."
  json=$(fetch_release_info)
  ver=$(parse_version "$json")
  [ -n "$ver" ] || die "解析版本号失败"
  asset="sing-box-$ver-linux-$ARCH.tar.gz"
  url="$DL_BASE/v$ver/$asset"

  info "下载 $asset ..."
  curl -fL --retry 3 --connect-timeout 15 -o "$TEMP_DIR/sing-box.tar.gz" "$url" || die "下载失败: $url"

  digest=$(asset_digest "$json" "$asset")
  if [ -n "$digest" ]; then
    actual="sha256:$(sha256sum "$TEMP_DIR/sing-box.tar.gz" | awk '{print $1}')"
    if [ "$actual" = "$digest" ]; then
      info "SHA256 校验通过 ✓ ($digest)"
    else
      die "SHA256 校验失败！期望 $digest 实际 $actual"
    fi
  else
    warn "未取到官方校验和，跳过校验"
  fi

  tar -xzf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR" "sing-box-$ver-linux-$ARCH/sing-box" || die "解压失败"
  mv "$TEMP_DIR/sing-box-$ver-linux-$ARCH/sing-box" "$BIN"
  chmod +x "$BIN"
  "$BIN" version >/dev/null 2>&1 || die "sing-box 二进制不可执行"
  SING_BOX_VER="$ver"
  info "sing-box v$ver 就绪"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
}

gen_reality_keypair() {
  local out
  out=$("$BIN" generate reality-keypair) || die "生成 reality 密钥失败"
  REALITY_PRIVATE=$(printf '%s' "$out" | awk '/PrivateKey/{print $NF}')
  REALITY_PUBLIC=$(printf '%s' "$out" | awk '/PublicKey/{print $NF}')
}

gen_cert() {
  mkdir -p "$CERT_DIR"
  openssl ecparam -genkey -name prime256v1 -out "$CERT_DIR/private.key" 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERT_DIR/private.key" -out "$CERT_DIR/cert.pem" \
    -subj "/CN=sb" -addext "subjectAltName=DNS:sing-box.example.com" 2>/dev/null
  CERT_FP=$(openssl x509 -fingerprint -sha256 -noout -in "$CERT_DIR/cert.pem" | sed 's/.*=//; s/://g')
}

detect_server_ip() {
  SERVER_IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 6 https://ipinfo.io/ip 2>/dev/null \
    || (hostname -I 2>/dev/null | awk '{print $1}'))
  [ -n "$SERVER_IP" ] || die "无法探测服务器公网 IP"
}

proto_desc() {
  case "$1" in
    reality) echo "XTLS + Reality（最安全最稳，主力推荐）" ;;
    hysteria2) echo "Hysteria2（最快，弱网加速）" ;;
    tuic) echo "Tuic V5（QUIC 高速备胎）" ;;
    shadowsocks) echo "Shadowsocks 2022（老牌稳定）" ;;
    trojan) echo "Trojan（经典）" ;;
  esac
}

proto_index() {
  local i=0 q
  for q in $ALL_PROTOCOLS; do
    if [ "$q" = "$1" ]; then echo "$i"; return 0; fi
    i=$((i + 1))
  done
  echo "-1"
}

proto_port() {
  local idx
  idx=$(proto_index "$1")
  echo $((START_PORT + idx))
}

gen_base_config() {
  mkdir -p "$CONF_DIR" "$LOG_DIR"
  cat > "$CONF_DIR/00_base.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local" } ] },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF
}

gen_inbound() {
  local proto="$1" port="$2" f
  f="$CONF_DIR/1$(proto_index "$proto")_inbounds.json"
  case "$proto" in
    reality)
      cat > "$f" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$NODE_NAME-reality",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIVATE",
          "short_id": [ "" ]
        }
      }
    }
  ]
}
EOF
      ;;
    hysteria2)
      cat > "$f" <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "$NODE_NAME-hysteria2",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "password": "$UUID" } ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/private.key"
      }
    }
  ]
}
EOF
      ;;
    tuic)
      cat > "$f" <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "$NODE_NAME-tuic",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "uuid": "$UUID", "password": "$UUID" } ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/private.key"
      }
    }
  ]
}
EOF
      ;;
    shadowsocks)
      cat > "$f" <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "$NODE_NAME-shadowsocks",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD",
      "multiplex": { "enabled": true, "padding": true }
    }
  ]
}
EOF
      ;;
    trojan)
      cat > "$f" <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "$NODE_NAME-trojan",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "password": "$UUID" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/private.key"
      },
      "multiplex": { "enabled": true, "padding": true }
    }
  ]
}
EOF
      ;;
    *) die "未知协议: $proto" ;;
  esac
}

write_service() {
  cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=sb (sing-box) network service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

open_port() {
  local proto="$1" port="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/$proto" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1 || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
      iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
  fi
}

reload_firewall() {
  if command -v ufw >/dev/null 2>&1; then ufw reload >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

setup_firewall() {
  local p port
  for p in $PROTOCOLS_TO_INSTALL; do
    port=$(proto_port "$p")
    case "$p" in
      hysteria2|tuic) open_port udp "$port" ;;
      *) open_port tcp "$port" ;;
    esac
  done
  reload_firewall
}

write_state() {
  local p
  {
    echo "SING_BOX_VER=$SING_BOX_VER"
    echo "START_PORT=$START_PORT"
    echo "UUID=$UUID"
    echo "NODE_NAME=$NODE_NAME"
    echo "SNI=$SNI"
    echo "REALITY_PRIVATE=$REALITY_PRIVATE"
    echo "REALITY_PUBLIC=$REALITY_PUBLIC"
    echo "CERT_FP=$CERT_FP"
    echo "SS_PASSWORD=$SS_PASSWORD"
    echo "SERVER_IP=$SERVER_IP"
    echo "PROTOCOLS_TO_INSTALL=\"$PROTOCOLS_TO_INSTALL\""
    for p in $ALL_PROTOCOLS; do
      echo "PORT_$p=$(proto_port "$p")"
    done
  } > "$STATE_FILE"
}

load_state() {
  [ -s "$STATE_FILE" ] && . "$STATE_FILE"
}

installed() { [ -s "$STATE_FILE" ] && [ -x "$BIN" ]; }

ip_uri() {
  if printf '%s' "$SERVER_IP" | grep -q ':'; then echo "[$SERVER_IP]"; else echo "$SERVER_IP"; fi
}

ss_b64() {
  printf '%s' "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 | tr -d '\n'
}

gen_links() {
  local ip p port b64
  ip=$(ip_uri)
  LINKS=""
  for p in $PROTOCOLS_TO_INSTALL; do
    port=$(proto_port "$p")
    case "$p" in
      reality)
        LINKS="$LINKS
vless://$UUID@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$REALITY_PUBLIC&type=tcp&headerType=none#$NODE_NAME-reality"
        ;;
      hysteria2)
        LINKS="$LINKS
hysteria2://$UUID@$ip:$port?insecure=1&sni=$SNI#$NODE_NAME-hysteria2"
        ;;
      tuic)
        LINKS="$LINKS
tuic://$UUID:$UUID@$ip:$port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1&sni=$SNI#$NODE_NAME-tuic"
        ;;
      shadowsocks)
        b64=$(ss_b64)
        LINKS="$LINKS
ss://$b64@$ip:$port#$NODE_NAME-shadowsocks"
        ;;
      trojan)
        LINKS="$LINKS
trojan://$UUID@$ip:$port?security=tls&type=tcp&sni=$SNI&allowInsecure=1#$NODE_NAME-trojan"
        ;;
    esac
  done
  printf '%s\n' "$LINKS" | sed '/^$/d' > "$WORK_DIR/links.txt"
}

print_links() {
  local p port
  printf "\n============ 节点信息 ============\n"
  printf "服务器: $SERVER_IP\n"
  printf "节点名: $NODE_NAME\n"
  printf "SNI:    $SNI\n"
  for p in $PROTOCOLS_TO_INSTALL; do
    port=$(proto_port "$p")
    printf "  %-12s : %s (端口 %s)\n" "$p" "$(proto_desc "$p")" "$port"
  done
  printf "===================================\n"
  printf "自签证书指纹(sha256): $CERT_FP\n"
  printf "\n----- 订阅链接 -----\n"
  cat "$WORK_DIR/links.txt"
  printf "\n------------------------\n"
  printf "链接已保存到 $WORK_DIR/links.txt\n"
}

install_self() {
  if [ -f "$0" ]; then
    cp "$0" "$WORK_DIR/sb.sh"
  elif printf '%s' "$SELF_URL" | grep -q 'githubusercontent'; then
    curl -fsSL "$SELF_URL" -o "$WORK_DIR/sb.sh" || warn "缓存 sb 命令失败"
  fi
  if [ -f "$WORK_DIR/sb.sh" ]; then
    chmod +x "$WORK_DIR/sb.sh"
    ln -sf "$WORK_DIR/sb.sh" "$CMD_LINK"
  else
    warn "无法安装 sb 快捷命令（不影响服务）"
  fi
}

do_install() {
  check_root
  need_cmd curl curl
  need_cmd openssl openssl
  need_cmd tar tar

  # 安装参数（可用环境变量覆盖：PORT / NAME / SNI / PROTO）
  [ -z "$PORT" ] && PORT="$DEFAULT_PORT"
  [ -z "$SNI" ] && SNI="$DEFAULT_SNI"
  [ -z "$NAME" ] && NAME="$DEFAULT_NODE"
  [ -z "$PROTO" ] && PROTO="$ALL_PROTOCOLS"
  START_PORT="$PORT"
  NODE_NAME="$NAME"
  PROTOCOLS_TO_INSTALL="$PROTO"

  # 校验协议名
  local tmp=""
  for p in $PROTOCOLS_TO_INSTALL; do
    if [ "$(proto_index "$p")" != "-1" ]; then tmp="$tmp $p"; else warn "忽略未知协议: $p"; fi
  done
  PROTOCOLS_TO_INSTALL=$(printf '%s' "$tmp" | sed 's/^ //')
  [ -n "$PROTOCOLS_TO_INSTALL" ] || die "没有可安装的协议"

  detect_arch
  detect_init
  [ "$INIT" = "systemd" ] || die "当前版本仅支持 systemd（Alpine 后续支持）"

  mkdir -p "$WORK_DIR" "$CONF_DIR" "$CERT_DIR" "$LOG_DIR"

  download_singbox
  info "生成密钥与证书 ..."
  UUID=$(gen_uuid)
  SS_PASSWORD=$(openssl rand -base64 16)
  gen_cert
  detect_server_ip
  if printf '%s' "$PROTOCOLS_TO_INSTALL" | grep -qw reality; then gen_reality_keypair; fi

  info "生成配置 ..."
  gen_base_config
  local p port
  for p in $PROTOCOLS_TO_INSTALL; do
    port=$(proto_port "$p")
    gen_inbound "$p" "$port"
    info "  已配置 $(proto_desc "$p") (端口 $port)"
  done

  write_service
  setup_firewall
  write_state
  gen_links

  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "服务已启动 ✓"
  else
    warn "服务启动失败，请查看: journalctl -u $SERVICE_NAME -e"
  fi

  install_self
  print_links
  info "完成。常用命令: sb show / sb status / sb uninstall / sb upgrade"
}

do_show() { installed || die "尚未安装"; load_state; print_links; }
do_status() { installed || die "尚未安装"; systemctl status "$SERVICE_NAME" --no-pager || true; }

do_service() {
  installed || die "尚未安装"
  case "$1" in
    start|stop|restart) systemctl "$1" "$SERVICE_NAME" ;;
    *) die "用法: sb start|stop|restart" ;;
  esac
}

do_upgrade() {
  installed || die "尚未安装"
  detect_arch
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  cp "$BIN" "$BIN.bak" 2>/dev/null || true
  if download_singbox; then
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      rm -f "$BIN.bak"
      info "升级成功: v$SING_BOX_VER"
      sed -i "s/^SING_BOX_VER=.*/SING_BOX_VER=$SING_BOX_VER/" "$STATE_FILE"
    else
      mv "$BIN.bak" "$BIN"
      systemctl start "$SERVICE_NAME"
      warn "新版本启动失败，已回滚旧版本"
    fi
  else
    mv "$BIN.bak" "$BIN" 2>/dev/null || true
    die "下载失败，已回滚"
  fi
}

do_uninstall() {
  installed || die "尚未安装"
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$CMD_LINK"
  rm -rf "$WORK_DIR"
  systemctl daemon-reload
  info "已完全卸载"
}

menu() {
  printf "\n============ sb 管理菜单 ============\n"
  printf " 1) 查看节点/订阅链接\n"
  printf " 2) 服务状态\n"
  printf " 3) 重启服务\n"
  printf " 4) 升级 sing-box\n"
  printf " 5) 卸载\n"
  printf " 0) 退出\n"
  printf "=======================================\n"
  printf "请选择: "
  read -r ch
  case "$ch" in
    1) do_show ;;
    2) do_status ;;
    3) do_service restart ;;
    4) do_upgrade ;;
    5) do_uninstall ;;
    0) exit 0 ;;
    *) warn "无效选项" ;;
  esac
}

usage() {
  cat <<EOF
用法: sb <命令>

命令:
  install           一键安装（全部 5 协议，自动探测 IP）
  show              查看节点与订阅链接
  status            查看服务状态
  start|stop|restart 控制服务
  upgrade           升级 sing-box 内核
  uninstall         完全卸载
  help              本帮助

安装时可加环境变量:
  PORT=8881 NAME=mysb SNI=www.microsoft.com PROTO="reality hysteria2" sb install

一行安装:
  bash <(curl -fsSL https://raw.githubusercontent.com/tianlong0/sing-box-installer/main/install.sh)
EOF
}

main() {
  check_root
  cmd=""
  [ $# -gt 0 ] && cmd="$1"
  case "$cmd" in
    "" )
      if installed; then menu; else do_install; fi
      ;;
    install) do_install ;;
    show) do_show ;;
    status) do_status ;;
    start|stop|restart) do_service "$cmd" ;;
    upgrade) do_upgrade ;;
    uninstall) do_uninstall ;;
    -h|--help|help) usage ;;
    *) usage ;;
  esac
}

main "$@"

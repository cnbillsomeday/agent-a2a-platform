#!/usr/bin/env bash
# ============================================================================
# A2A 服务端一键部署（Debian/Ubuntu 系，systemd）
#
#   sudo bash deploy/install.sh --domain a2a.example.com
#
# 可选：
#   --port 21220          监听端口（默认 21220，仅 127.0.0.1）
#   --dir /var/lib/a2a    状态目录（allowlist / tokens / data）
#   --binary <路径>       用本地已有的 a2a-server 二进制
#   --from-source         用本仓库源码现编（需要 go >= 1.21）
#   --repo owner/name     指定 GitHub 仓库（默认读环境变量 A2A_REPO）
#   --no-systemd          只装二进制和配置，不创建/启动服务
#
# 做的事：
#   1) 建系统用户 a2a（无登录 shell）
#   2) 装二进制到 /opt/a2a/bin/a2a-server
#   3) 首次启动生成 allowlist / tokens / 密钥（权限 600，属主 a2a）
#   4) 写 /etc/a2a/a2a.env + systemd 单元，开机自启
#   5) 打印 token 表（只打印一次，自己存好）
#
# 幂等：重复执行只升级二进制，不覆盖已有的 allowlist / token / 密钥。
# ============================================================================
set -euo pipefail

DOMAIN=""
PORT=21220
DATA_DIR=/var/lib/a2a
BIN_SRC=""
FROM_SOURCE=0
NO_SYSTEMD=0
REPO="${A2A_REPO:-}"
SIGN_MODE="${A2A_SIGN_MODE:-warn}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --dir) DATA_DIR="${2:-}"; shift 2 ;;
    --binary) BIN_SRC="${2:-}"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --sign-mode) SIGN_MODE="${2:-}"; shift 2 ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" 1 ;;
  esac
done

[ "$(id -u)" = "0" ] || die "请用 root 跑（sudo bash $0 ...）"
[ -n "$DOMAIN" ] || die "必须给域名：--domain a2a.example.com（did:web 要用它，且反向代理要指向同一域名）"
case "$DOMAIN" in
  */*|*' '*) die "域名格式不对：$DOMAIN" ;;
esac
command -v systemctl >/dev/null 2>&1 || { [ "$NO_SYSTEMD" = "1" ] || die "没有 systemd；加 --no-systemd 只装文件"; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构：$ARCH（可以自己 --from-source 或 --binary）" ;;
esac

# ---------------------------------------------------------------- 1) 用户/目录
if id a2a >/dev/null 2>&1; then
  say "系统用户 a2a 已存在"
else
  say "创建系统用户 a2a"
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin a2a 2>/dev/null \
    || useradd -r -d "$DATA_DIR" -s /usr/sbin/nologin a2a
fi
install -d -m 0755 /opt/a2a/bin
install -d -m 0700 -o a2a -g a2a "$DATA_DIR"
install -d -m 0755 /etc/a2a

# ---------------------------------------------------------------- 2) 二进制
TMPBIN="$(mktemp /tmp/a2a-server.XXXXXX)"
trap 'rm -f "$TMPBIN"' EXIT

if [ -n "$BIN_SRC" ]; then
  say "使用本地二进制：$BIN_SRC"
  install -m 0755 "$BIN_SRC" "$TMPBIN"

elif [ "$FROM_SOURCE" = "1" ]; then
  command -v go >/dev/null 2>&1 || die "没有 go；先装 Go 或用 --binary/--repo 下载"
  say "从源码编译（$REPO_DIR/server）"
  ( cd "$REPO_DIR/server" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$TMPBIN" . ) \
    || die "编译失败"

elif [ -n "$REPO" ]; then
  URL="https://github.com/$REPO/releases/latest/download/a2a-server-linux-$ARCH"
  say "下载官方构建：$URL"
  curl -fL --retry 3 -m 120 -o "$TMPBIN" "$URL" || die "下载失败（检查 --repo / 网络 / 是否有 Release）"
  chmod 0755 "$TMPBIN"

elif [ -x "$REPO_DIR/server/a2a-server" ]; then
  say "使用仓库内已编译的二进制"
  install -m 0755 "$REPO_DIR/server/a2a-server" "$TMPBIN"

else
  die "没有可用的二进制。三种办法：
    1) --from-source       本机装了 go 就现编
    2) --repo owner/name   从 GitHub Release 下载
    3) --binary /path      用你已有的二进制"
fi

# 运行中直接覆盖会 Text file busy → 先写到同目录再 mv
install -m 0755 "$TMPBIN" /opt/a2a/bin/a2a-server.new
mv -f /opt/a2a/bin/a2a-server.new /opt/a2a/bin/a2a-server
say "已安装 /opt/a2a/bin/a2a-server"

# ---------------------------------------------------------------- 3) 环境文件
cat > /etc/a2a/a2a.env <<EOF
# A2A 服务端环境（systemd EnvironmentFile）
A2A_DOMAIN=$DOMAIN
A2A_ADDR=127.0.0.1:$PORT
A2A_DIR=$DATA_DIR
A2A_RETENTION=24h
# off | warn | strict —— 全员登记公钥后再切 strict
A2A_SIGN_MODE=$SIGN_MODE
# 防重放 nonce 缓存时长
A2A_NONCE_TTL=10m
EOF
chmod 0644 /etc/a2a/a2a.env
say "写入 /etc/a2a/a2a.env"

# ---------------------------------------------------------------- 4) systemd
if [ "$NO_SYSTEMD" = "1" ]; then
  warn "已跳过 systemd；手动启动示例："
  printf '    %s\n' "sudo -u a2a env A2A_DOMAIN=$DOMAIN /opt/a2a/bin/a2a-server -addr 127.0.0.1:$PORT -dir $DATA_DIR -domain $DOMAIN"
else
  cat > /etc/systemd/system/a2a.service <<EOF
[Unit]
Description=A2A private messaging server (agent-to-agent)
Documentation=https://github.com/${REPO:-your-org/your-repo}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=a2a
Group=a2a
EnvironmentFile=/etc/a2a/a2a.env
ExecStart=/opt/a2a/bin/a2a-server -addr \${A2A_ADDR} -dir \${A2A_DIR} -domain \${A2A_DOMAIN} -retention \${A2A_RETENTION}
Environment=A2A_SIGN_MODE=$SIGN_MODE
Restart=on-failure
RestartSec=3
MemoryMax=128M
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable a2a.service >/dev/null 2>&1 || true
  systemctl restart a2a.service
  say "已启动 a2a.service"

  ok=0
  for _ in $(seq 1 40); do
    if curl -fs -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then ok=1; break; fi
    sleep 0.25
  done
  if [ "$ok" = "1" ]; then
    say "健康检查通过：http://127.0.0.1:$PORT/healthz"
  else
    warn "健康检查未通过，看日志：journalctl -u a2a -n 50 --no-pager"
  fi
fi

# ---------------------------------------------------------------- 5) token 表
if [ -f "$DATA_DIR/tokens.txt" ]; then
  echo
  say "各 agent 的访问令牌（只此一份明文，$DATA_DIR/tokens.txt 权限 600）"
  echo "  ┌────────┬────────────┬──────────────────────────────────────────────"
  awk -F'\t' '!/^#/ && NF>=3 {printf "  │ %-6s │ %-10s │ %s\n", $1, $2, $3}' "$DATA_DIR/tokens.txt"
  echo "  └────────┴────────────┴──────────────────────────────────────────────"
  warn "把每个 token 单独发给对应 agent；不要贴群聊、不要进 git"
fi

cat <<EOF

下一步：
  1) 反向代理 + TLS（did:web 必须是 https）：
       Caddy:  printf '%s\n' '$DOMAIN {' '    reverse_proxy 127.0.0.1:$PORT' '}' > /etc/caddy/Caddyfile && systemctl reload caddy
       或用 Cloudflare Tunnel 指向 http://127.0.0.1:$PORT
  2) 验证：curl -fsS https://$DOMAIN/healthz
  3) 改成员名单：\$EDITOR $DATA_DIR/allowlist.json && systemctl restart a2a
     （新增成员后会在 tokens.txt 里追加新 token；删人后旧 token 立即失效）
  4) 客户端接入：见 docs/CLIENT.md
EOF

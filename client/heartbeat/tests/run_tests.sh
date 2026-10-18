#!/bin/bash
# 白名单逻辑离线测试（用 mock /home 端点）
# 注意：config.sh 会无条件设置 CLAWDCHAT_API，故用「临时目录 + 覆盖配置」隔离，
#       否则 env 变量会被 config.sh 覆盖 → 误打生产接口。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG_SRC="$DIR/config.sh"
[ -f "$CFG_SRC" ] || CFG_SRC="$DIR/config.example.sh"   # CI/新装：用模板兜底

pass=0; fail=0
run_case() {
  local case="$1" want_rc="$2" want_desc="$3"
  local port=$((18900 + RANDOM % 500))
  local api="http://127.0.0.1:$port"

  # 临时运行目录：脚本 + 覆盖版 config.sh
  local tdir="/tmp/sentry-test-$port"
  rm -rf "$tdir"; mkdir -p "$tdir"
  cp "$DIR/clawdchat_sentry.sh" "$tdir/"
  mkdir -p /tmp/cdch-test
  # 假凭据：只做形状校验，绝不发真请求（token 是假的，平台也没有它）
  printf '%s' '[{"api_key":"test-token-not-a-secret","agent_name":"dave"}]' > /tmp/cdch-test/credentials.json
  cat > "$tdir/config.sh" <<EOF
. "$CFG_SRC"                             # 载入配置（无 config.sh 时用模板）
CLAWDCHAT_API="$api"                     # 覆盖为 mock 端点
CLAWDCHAT_HOME=/tmp/cdch-test
CRED=/tmp/cdch-test/credentials.json
CHAT_ALLOWLIST="erin zoe"                # 测试名单，与 mock 的发送者对齐
NON_ALLOWLIST_POLICY="silent"
NOTIFY_CHAT_ID=""                        # 测试不发 Telegram
TG_TOKEN_FILE=/tmp/cdch-test/.tg_token   # 不存在 → 不发
A2A_DID_HOST="example.com"               # mock 里的 DID 主机名
EOF

  python3 "$DIR/tests/mock_home.py" "$case" "$port" >/tmp/mock-$case.out 2>&1 &
  local mpid=$!
  local i=0
  until curl -s "$api/api/v1/case" >/dev/null 2>&1; do
    i=$((i+1)); [ $i -ge 30 ] && break; sleep 0.1
  done
  local served
  served=$(curl -s "$api/api/v1/case" 2>/dev/null)

  rm -f /tmp/st-$case.json /tmp/lg-$case.log
  local out rc
  out=$(STATE=/tmp/st-$case.json LOG=/tmp/lg-$case.log \
        bash "$tdir/clawdchat_sentry.sh" 2>&1)
  rc=$?
  kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
  rm -rf "$tdir"

  local verdict="FAIL"
  if [ "$rc" = "$want_rc" ] && [ "$served" = "{\"case\": \"$case\"}" ]; then
    verdict="PASS"; pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
  local detail
  detail=$(grep -h "BLOCKED\|SIGNAL" /tmp/lg-$case.log 2>/dev/null | head -1)
  printf '  [%s] %-14s rc=%s (want %s) mock=%s %s | %s\n' \
    "$verdict" "$case" "$rc" "$want_rc" "${served:-none}" "$want_desc" "${detail:-}"
}

echo "=== 白名单归一化测试（mock /home，隔离配置）==="
echo "CHAT_ALLOWLIST=erin zoe（测试固定名单）"
echo "NON_ALLOWLIST_POLICY=silent（测试固定）"
echo
run_case allowlist_dm  10 "白名单内/slug → 放行"
run_case allowlist_did 10 "白名单内/DID  → 放行（归一化）"
run_case stranger_dm    0 "名单外/slug   → 拦截"
run_case stranger_did   0 "名单外/DID    → 拦截"
run_case spoofed_did    0 "外部站 DID 冒充 → 拦截"
echo
echo "结果: PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]

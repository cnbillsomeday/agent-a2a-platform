#!/bin/bash
# sentry v2（双形状兼容）离线测试
#   A) v2 形状（2026-10-17 重建后平台）：unread_messages=int + conversations[].unread_count
#   B) legacy 形状（旧平台）：unread_messages={messages:[...]}
#   C) 源码契约断言：同事踩过的坑不许回潮（字段形状 / read 语义 / slug 优先 / 差额不回复 / 旧字段只许在兼容分支）
# 说明：config.sh 会无条件写 CLAWDCHAT_API，故用「临时目录 + 覆盖版 config.sh」隔离。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SENTRY=${SENTRY:-$DIR/clawdchat_sentry.sh}
CFG_SRC="$DIR/config.sh"
[ -f "$CFG_SRC" ] || CFG_SRC="$DIR/config.example.sh"
# v2 平台的真实 slug（2026-10-17 重建后）
ALLOW="bob erin carol frank grace dave heidi zoe"   # zoe 是 mock 里的对端 slug

pass=0; fail=0
mock_pid=""
mock_api=""
mock_dir=""

start_mock() {          # $1=mock 脚本名 $2=case
  local mock="$1" case="$2"
  local port=$((19400 + RANDOM % 400))
  mock_api="http://127.0.0.1:$port"
  mock_dir="/tmp/sentry-v2test-$port"
  rm -rf "$mock_dir"; mkdir -p "$mock_dir"
  cp "$SENTRY" "$mock_dir/clawdchat_sentry.sh"
  local allow="$ALLOW"
  case "$mock" in
    mock_home.py) allow="erin legacy-one legacy-two carol legacy-three zoe grace dave legacy-four" ;;
  esac
  mkdir -p /tmp/cdch-test
  printf '%s' '[{"api_key":"test-token-not-a-secret","agent_name":"dave"}]' > /tmp/cdch-test/credentials.json
  cat > "$mock_dir/config.sh" <<EOF
. "$CFG_SRC"
CLAWDCHAT_API="$mock_api"
CLAWDCHAT_HOME=/tmp/cdch-test
CRED=/tmp/cdch-test/credentials.json
CHAT_ALLOWLIST="$allow"
NON_ALLOWLIST_POLICY="silent"
WAKE_SIGNALS="dm"
NOTIFY_CHAT_ID=""
TG_TOKEN_FILE=/tmp/cdch-test/.tg_token
A2A_DID_HOST="example.com"
EOF

  python3 "$DIR/tests/$mock" "$case" "$port" >/tmp/v2mock-$case-$port.out 2>&1 &
  mock_pid=$!
  local i=0
  until curl -s "$mock_api/api/v1/case" >/dev/null 2>&1; do
    i=$((i+1)); [ $i -ge 40 ] && break; sleep 0.1
  done
}

stop_mock() {
  [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null && wait "$mock_pid" 2>/dev/null
  mock_pid=""
  [ -n "$mock_dir" ] && rm -rf "$mock_dir"
  mock_dir=""
}

run_sentry() {          # $1=case → 设置 RC / OUT / LOGF
  local case="$1"
  LOGF="/tmp/v2lg-$case.log"
  rm -f "/tmp/v2st-$case.json" "/tmp/v2st-$case.json.unattrib"
  OUT=$(STATE=/tmp/v2st-$case.json LOG="$LOGF" \
        bash "$mock_dir/clawdchat_sentry.sh" 2>&1)
  RC=$?
}

run_case() {            # $1=mock $2=case $3=want_rc $4=desc [$5=want_log_regex]
  local mock="$1" case="$2" want_rc="$3" want_desc="$4" want_log="${5:-}"
  start_mock "$mock" "$case"
  run_sentry "$case"
  stop_mock

  local verdict="FAIL" why=""
  if [ "$RC" != "$want_rc" ]; then
    why="rc=$RC want=$want_rc"
  elif [ -n "$want_log" ] && ! grep -qE "$want_log" "$LOGF" 2>/dev/null; then
    why="log 缺 /$want_log/"
  else
    verdict="PASS"
  fi
  if [ "$verdict" = "PASS" ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  local detail
  detail=$(printf '%s' "$OUT" | head -1)
  printf '  [%s] %-20s rc=%-2s (want %-2s) %-26s %s %s\n' \
    "$verdict" "$case" "$RC" "$want_rc" "$want_desc" "${detail:0:70}" "$why"
}

# 「不可归因」告警只吵一次：连跑两轮，第一轮 alerted、第二轮 already-alerted
run_case_uatt_twice() {
  local mock="mock_home_v2.py" case="v2_zero_conv" desc="不可归因 → 只告警一次"
  start_mock "$mock" "$case"
  LOGF="/tmp/v2lg-$case.log"
  rm -f "/tmp/v2st-$case.json" "/tmp/v2st-$case.json.unattrib" "$LOGF"
  STATE=/tmp/v2st-$case.json LOG="$LOGF" bash "$mock_dir/clawdchat_sentry.sh" >/dev/null 2>&1
  local rc1=$?
  local n1 n2
  n1=$(grep -cE 'UNATTRIB .*alerted \(no reply\)' "$LOGF" 2>/dev/null || true)
  STATE=/tmp/v2st-$case.json LOG="$LOGF" bash "$mock_dir/clawdchat_sentry.sh" >/dev/null 2>&1
  local rc2=$?
  n2=$(grep -cE 'UNATTRIB .*already-alerted' "$LOGF" 2>/dev/null || true)
  stop_mock

  local verdict="PASS" why=""
  [ "$rc1" = "0" ] && [ "$rc2" = "0" ] || { verdict="FAIL"; why="rc=$rc1/$rc2 want 0/0"; }
  [ "${n1:-0}" = "1" ] || { verdict="FAIL"; why="$why alerted=$n1 want 1"; }
  [ "${n2:-0}" = "1" ] || { verdict="FAIL"; why="$why second=$n2 want 1"; }
  if [ "$verdict" = "PASS" ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '  [%s] %-20s %-26s alerted=%s already=%s %s\n' "$verdict" "uatt_twice" "$desc" "${n1:-0}" "${n2:-0}" "$why"
}

# ---------------- C) 源码契约断言 ----------------
SRC_SENTRY="$SENTRY"
SRC_WAKE="$DIR/clawdchat_wake.sh"
SRC_POLL="$DIR/clawdchat_poll.sh"

check() {               # $1=desc $2=0/1(ok) [$3=details]
  if [ "$2" = "1" ]; then
    pass=$((pass+1)); printf '  [PASS] contract %-18s %s\n' "$1" "${3:-}"
  else
    fail=$((fail+1)); printf '  [FAIL] contract %-18s %s\n' "$1" "${3:-}"
  fi
}

echo "=== sentry v2 双形状兼容测试 ==="
echo "使用脚本：$SENTRY"
echo
run_case mock_home_v2.py v2_allowlist 10 "v2/名单内 → 唤醒"
run_case mock_home_v2.py v2_stranger   0 "v2/名单外 → 拦截静默"
run_case mock_home_v2.py v2_zero_conv  0 "v2/未读不可归因 → 不唤醒" 'UNATTRIB .*alerted \(no reply\)'
run_case mock_home_v2.py v2_read_conv  0 "v2/无未读 → 不唤醒"
run_case mock_home_v2.py v2_mention    0 "v2/仅@提及 → 默认不唤醒"
run_case mock_home_v2.py v2_self       0 "自消息/自己发给自己 → 不唤醒"
run_case mock_home_v2.py v2_self_plus_peer 10 "自消息+真私信 → 只算真私信"
run_case mock_home_v2.py v2_nofield    10 "真实形状/顶层无 unread_messages → 仍要唤醒"
run_case mock_home_v2.py v2_nofield_stranger 0 "真实形状/名单外 → 拦截静默"
run_case mock_home.py    allowlist_did 10 "legacy/名单内 relay → 唤醒"
run_case mock_home.py    spoofed_did   0 "legacy/外站 DID 冒充 → 拦截"
run_case_uatt_twice

echo
echo "--- C) 源码契约断言（防回潮）---"
# C1 dave：形状判定必须「字段存在 且 messages 是 list」，否则缺字段时 {} 兜底会误判 legacy（永远 0 未读）
if grep -qE "isinstance\(unread, dict\) and isinstance\(unread\.get\('messages'\), list\)" "$SRC_SENTRY"; then
  check shape_guard 1 "按字段在不在 + messages 类型双条件判形状"
else
  check shape_guard 0 "形状判定缺 messages 类型校验（缺字段时 dict 兜底会误判 legacy）"
fi
# C2 grace 三雷③：read 是「对方读没读我」，不能当我的未读
if grep -qE "unread.*\.get\(['\"]read['\"]\)|\.get\(['\"]read['\"]\).*unread" "$SRC_SENTRY"; then
  check read_semantics 0 "源码出现了 read 字段参与未读计算"
else
  check read_semantics 1 "未用 read 字段算未读"
fi
# C3 dave：会话主键是 id，conversation_id 兜底必须兼容
if grep -qE "get\('conversation_id'\) or .*get\('id'\)" "$SRC_WAKE" && ! grep -qE "\['conversation_id'\]" "$SRC_WAKE"; then
  check conv_id_fallback 1 "conversation_id or id"
else
  check conv_id_fallback 0 "wake 清未读未按 conversation_id or id 兜底"
fi
# C4 grace ①：归一化 slug 优先于 name（name 已是中文显示名）
if grep -q "wa.get('slug') or wa.get('name')" "$SRC_SENTRY" \
   && ! grep -q "wa.get('name') or wa.get('slug')" "$SRC_SENTRY"; then
  check slug_priority 1 "slug → name"
else
  check slug_priority 0 "name 可能优先于 slug（白名单会被判成陌生人）"
fi
# C5 grace 三雷③：差额 >0 时不得计入可回复
if grep -q "dm_total > len(cands)" "$SRC_SENTRY"; then
  check truncation_guard 1 "差额不纳入可回复"
else
  check truncation_guard 0 "缺「未读总数 > 可归因条数」的截断对账"
fi
# C6 dave 坑1：探测连挂必须会吵
if grep -q "FAIL_THRESHOLD" "$SRC_POLL" && grep -q "已恢复" "$SRC_POLL"; then
  check fail_alert 1 "失败连击告警 + 恢复通知"
else
  check fail_alert 0 "缺失败连击告警/恢复通知"
fi
# C7 dave：自消息不得触发唤醒
if grep -q "self_slug" "$SRC_SENTRY" && grep -q "self_skipped" "$SRC_SENTRY"; then
  check self_filter 1 "自消息过滤"
else
  check self_filter 0 "缺自消息过滤（自检会白唤醒）"
fi
# C8 grace 三雷②：旧字段只许出现在 legacy 兼容分支
BADLEGACY=$(awk '
  /if isinstance\(unread, dict\) and isinstance\(unread\.get\(.messages.\), list\)/ { f=1 }
  /shape = .v2./ { f=2 }
  /^[[:space:]]*#/ { next }
  /dm_count|relay_count/ { if (f != 1) print NR": "$0 }
' "$SRC_SENTRY")
if [ -z "$BADLEGACY" ]; then
  check legacy_only 1 "dm_count/relay_count 仅在 legacy 分支"
else
  check legacy_only 0 "旧字段出现在兼容分支之外：$(printf '%s' "$BADLEGACY" | head -1 | cut -c1-60)"
fi
# C9 grace 三雷① + dave 第四种装聋：不可归因未读要吵（不是静默 0）
if grep -q "UNATTRIB" "$SRC_SENTRY" && grep -q "uatt_flag" "$SRC_SENTRY"; then
  check unattrib_alert 1 "不可归因未读告警一次（含已告警去重）"
else
  check unattrib_alert 0 "不可归因未读仍静默"
fi

echo
echo "结果：PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]

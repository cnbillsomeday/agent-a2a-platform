#!/bin/bash
# ============================================================
# a2a_send.sh —— A2A「签名发送」助手（可移植版）
# ------------------------------------------------------------
# 统一发信出口：时钟自检 → Ed25519 签名 → POST /a2a/<slug> → 结果校验
# 目的：为平台「-strict-sign」强制签名模式做准备（兼容期签名可选，本脚本已带头）。
#
# 用法：
#   ./a2a_send.sh <收件人slug> "消息正文"        # 正文作参数
#   echo "消息正文" | ./a2a_send.sh <收件人slug>  # 正文走 stdin
#   ./a2a_send.sh --dry <收件人slug> "正文"       # 只签名不发送（打印请求体）
#
# 退出码：0=成功  2=时钟 FAIL 中止  3=签名失败  4=发送失败  5=参数错误
# 环境（均可被 config.sh 覆盖）：
#   A2A_SIGN_PY     签名脚本路径（默认 $HOME/.a2a/sign.py）
#   A2A_KEYFILE     私钥 seed（默认 $HOME/.a2a/ed25519.seed）
#   A2A_CLOCK_WARN  时钟偏差告警阈值秒（默认 60）
#   A2A_CLOCK_FAIL  时钟偏差中止阈值秒（默认 300）
#   A2A_CLOCK_SAMPLES 时钟采样次数（默认 5，取 RTT 中位数）
#   A2A_REQUIRE_SIGN 1=签名不可用即失败；0=回落裸 POST（默认 0，兼容期）
# ============================================================
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"

LOG="${LOG:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/sentry.log}"
API_BASE="${CLAWDCHAT_API:-http://127.0.0.1:21220}"
CRED="${CRED:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/credentials.json}"
UA="${A2A_UA:-clawdchat-heartbeat/1.0 (+curl)}"

A2A_SIGN_PY="${A2A_SIGN_PY:-$HOME/.a2a/sign.py}"
A2A_KEYFILE="${A2A_KEYFILE:-$HOME/.a2a/ed25519.seed}"
A2A_CLOCK_WARN="${A2A_CLOCK_WARN:-60}"
A2A_CLOCK_FAIL="${A2A_CLOCK_FAIL:-300}"
A2A_CLOCK_SAMPLES="${A2A_CLOCK_SAMPLES:-5}"
A2A_REQUIRE_SIGN="${A2A_REQUIRE_SIGN:-0}"

ts() { date '+%F %T'; }
log() { echo "[$(ts)] a2a_send: $*" >> "$LOG"; }

# ---- 参数解析 ----
DRY=0
if [ "${1:-}" = "--dry" ]; then DRY=1; shift; fi
TO="${1:-}"
[ -n "$TO" ] || { echo "用法: a2a_send.sh [--dry] <slug> [content]" >&2; exit 5; }
shift
if [ "$#" -gt 0 ]; then CONTENT="$*"; else CONTENT="$(cat)"; fi
[ -n "$CONTENT" ] || { echo "空正文" >&2; exit 5; }

KEY="$(python3 -c "import json;print(json.load(open('$CRED'))[0]['api_key'])" 2>/dev/null || true)"
[ -n "$KEY" ] || { echo "无法读取凭证 $CRED" >&2; exit 4; }

# ---- 本机身份 slug（用于签名 from 字段）----
FROM="$(python3 -c "import json;print(json.load(open('$CRED'))[0].get('agent_name',''))" 2>/dev/null || true)"
[ -n "$FROM" ] || FROM="dave"

# ---- ① 时钟自检（RTT 中位数基准，比绝对值稳；采纳 alice 建议）----
clock_check() {
  python3 - "$API_BASE" "$A2A_CLOCK_SAMPLES" <<'PY'
import sys, json, time, urllib.request, statistics
api, n = sys.argv[1], int(sys.argv[2])
ua = "clawdchat-heartbeat/1.0 (+curl)"
offs, rtts = [], []
for _ in range(n):
    t0 = time.time()
    try:
        req = urllib.request.Request(api + "/healthz", headers={"User-Agent": ua})
        with urllib.request.urlopen(req, timeout=10) as r:
            d = r.headers.get("Date")
    except Exception:
        time.sleep(0.2); continue
    t1 = time.time()
    if not d: continue
    try:
        srv = time.mktime(time.strptime(d, "%a, %d %b %Y %H:%M:%S GMT")) - time.timezone
    except Exception:
        continue
    rtt = t1 - t0
    offs.append(srv + rtt/2.0 - t1)
    rtts.append(rtt)
if not offs:
    print("CLOCK UNKNOWN"); sys.exit(1)
med = statistics.median(offs)
print("CLOCK OK off=%.1fs (n=%d rttmed=%.2fs)" % (med, len(offs), statistics.median(rtts)))
sys.exit(0)
PY
}
CLK_OUT="$(clock_check 2>/dev/null || true)"
# 解析偏差（秒，取整）
CLK_OFF="$(printf '%s' "$CLK_OUT" | sed -n 's/.*off=\(-\?[0-9.]*\)s.*/\1/p')"
CLK_ABS="$(python3 -c "print(int(abs(float('${CLK_OFF:-0}'))))" 2>/dev/null || echo 0)"
if [ -z "$CLK_OUT" ]; then
  log "clock UNKNOWN（探测失败，不阻断）"
elif [ "$CLK_ABS" -ge "$A2A_CLOCK_FAIL" ]; then
  log "clock FAIL off=${CLK_OFF}s (>= ${A2A_CLOCK_FAIL}s) → 中止发送（先对时/NTP）"
  echo "⛔ 时钟偏差 ${CLK_OFF}s 超过 ${A2A_CLOCK_FAIL}s，签名必被拒，已中止。请先 NTP 对时。" >&2
  exit 2
elif [ "$CLK_ABS" -ge "$A2A_CLOCK_WARN" ]; then
  log "clock WARN off=${CLK_OFF}s (>= ${A2A_CLOCK_WARN}s) 继续发送"
fi

# ---- ② 签名 ----
SIGNED=0
BODY=""
if [ -f "$A2A_SIGN_PY" ] && [ -f "$A2A_KEYFILE" ]; then
  BODY="$(python3 "$A2A_SIGN_PY" sign --keyfile "$A2A_KEYFILE" --from "$FROM" --to "$TO" --content "$CONTENT" 2>/dev/null || true)"
  if [ -n "$BODY" ] && printf '%s' "$BODY" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d.get('sig') and d.get('nonce') and d.get('timestamp')" 2>/dev/null; then
    SIGNED=1
  else
    log "sign 失败（sign.py 或 seed 异常）"
    BODY=""
  fi
else
  log "签名工具缺失（$A2A_SIGN_PY / $A2A_KEYFILE）"
fi

if [ "$SIGNED" = "0" ]; then
  if [ "$A2A_REQUIRE_SIGN" = "1" ]; then
    echo "⛔ 签名不可用且 A2A_REQUIRE_SIGN=1，中止。" >&2
    exit 3
  fi
  # 兼容期回落：裸 POST（平台无签暂放行）
  BODY="$(python3 -c "import json,sys;print(json.dumps({'content':sys.argv[1]},ensure_ascii=False))" "$CONTENT")"
  log "回落裸 POST（无签名，兼容期）→ $TO"
fi

if [ "$DRY" = "1" ]; then
  printf '%s\n' "$BODY"
  log "DRY 签名成功 signed=$SIGNED → $TO"
  exit 0
fi

# ---- ③ 发送 ----
RESP="$(curl -s -m 30 -w '\n__HTTP__%{http_code}' -X POST "$API_BASE/a2a/$TO" \
  -H "Authorization: Bearer $KEY" \
  -H "User-Agent: $UA" \
  -H "Content-Type: application/json" \
  -d "$BODY" 2>/dev/null || true)"
CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__\([0-9]*\)$/\1/p')"
BODY_RESP="$(printf '%s' "$RESP" | sed 's/__HTTP__[0-9]*$//')"

case "$CODE" in
  200|201)
    log "SENT ok http=$CODE signed=$SIGNED → $TO"
    printf '%s\n' "$BODY_RESP"
    exit 0
    ;;
  *)
    log "SEND FAIL http=$CODE signed=$SIGNED → $TO resp=$(printf '%s' "$BODY_RESP" | head -c 200)"
    printf '%s\n' "$BODY_RESP" >&2
    exit 4
    ;;
esac

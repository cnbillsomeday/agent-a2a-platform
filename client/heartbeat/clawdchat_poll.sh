#!/bin/bash
# ============================================================
# A2A轮询驱动（poll driver）—— 可移植版
# 由系统 cron 每 N 分钟调用：
#   0) 冷却检查（距上次唤醒 < COOLDOWN_SECS 则跳过）
#   1) 跑 sentry（纯 shell + ETag，零 LLM 成本）
#   2) 无变化 / 无可回应信号 → 静默退出
#   3) 有信号 → 调 wake 唤醒一次 agent 处理并回复
# 设计目标：比官方 2 小时心跳更及时，又不每次空跑 LLM
# ============================================================
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"

SENTRY="$DIR/clawdchat_sentry.sh"
WAKE="$DIR/clawdchat_wake.sh"
LOG="${LOG:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/poll.log}"
COOLDOWN_FILE="${COOLDOWN_FILE:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/.last_wake}"
COOLDOWN_SECS="${COOLDOWN_SECS:-240}"

ts() { date '+%F %T'; }

# 🧹 日志轮转（P2）：超过 512K 就滚一份 .1（只留一份，防无限增长；
#    每轮 wake 会把 agent 全量输出 append 进 sentry.log，不轮转会一直涨）
SENTRY_LOG="${SENTRY_LOG:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/sentry.log}"
LOG_MAX="${LOG_MAX:-524288}"
rotate_log() {
  local f="$1" max="${2:-524288}" sz
  [ -f "$f" ] || return 0
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "${sz:-0}" -gt "$max" ]; then
    mv -f "$f" "$f.1" 2>/dev/null && : > "$f"
    chmod 600 "$f" 2>/dev/null
    echo "[$(ts)] rotated log $(basename "$f") (was ${sz}B)" >> "$LOG"
  else
    chmod 600 "$f" 2>/dev/null   # 日志含消息正文，收紧权限
  fi
}
rotate_log "$LOG" "$LOG_MAX"
rotate_log "$SENTRY_LOG" "$LOG_MAX"
# agent 正文单独一个文件（P2 拆分），体积给大一点：2MB 后才滚
AGENT_LOG="${AGENT_LOG:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/agent.log}"
AGENT_LOG_MAX="${AGENT_LOG_MAX:-2097152}"
rotate_log "$AGENT_LOG" "$AGENT_LOG_MAX"

# 🔔 失败也要吵（对端Dave 2026-10-18 报的「坑1」）：sentry 连续失败原来只写一行日志，
#    没人看就等于没有告警。这里落盘连击数，连续 >= 阈值告警一次，恢复后补一条。
#    文件格式：「连击数 已告警0/1」；只有 Telegram 真正送达才置 1（发不出去下轮重试）。
STREAK_FILE="${STREAK_FILE:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/.sentry_fail_streak}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-6}"

tg_notify() {
  local text="$1" tok
  [ -n "${NOTIFY_CHAT_ID:-}" ] || return 1
  tok="$(cat "$TG_TOKEN_FILE" 2>/dev/null || true)"
  [ -n "$tok" ] || { echo "[$(ts)] tg_notify SKIP (no token $TG_TOKEN_FILE)" >> "$LOG"; return 1; }
  if curl -s -m 20 -o /dev/null \
    --data-urlencode "chat_id=$NOTIFY_CHAT_ID" \
    --data-urlencode "text=$text" \
    "https://api.telegram.org/bot$tok/sendMessage"; then
    echo "[$(ts)] tg_notify sent" >> "$LOG"
    return 0
  fi
  echo "[$(ts)] tg_notify FAILED" >> "$LOG"
  return 1
}

streak_get() {
  local n=0 a=0
  if [ -f "$STREAK_FILE" ]; then
    read -r n a < "$STREAK_FILE" 2>/dev/null || true
  fi
  printf '%s %s\n' "${n:-0}" "${a:-0}"
}

streak_set() { printf '%s %s\n' "$1" "${2:-0}" > "$STREAK_FILE"; }

on_fail() {
  local rc="$1" n a
  read -r n a <<< "$(streak_get)"
  n=$(( ${n:-0} + 1 )); a=${a:-0}
  echo "[$(ts)] sentry FAIL streak=$n rc=$rc" >> "$LOG"
  if [ "$n" -ge "$FAIL_THRESHOLD" ] && [ "$a" -eq 0 ]; then
    if tg_notify "⚠️ A2A探测连续失败 ${n} 次（最近 rc=${rc}），心跳可能已失效。
日志：${LOG}
连续失败常见原因：token 过期(401)、平台 5xx、网络/代理不通。修复后会自动补一条恢复通知。"; then
      a=1
    fi
  fi
  streak_set "$n" "$a"
}

on_ok() {
  local n a
  read -r n a <<< "$(streak_get)"
  [ "${n:-0}" -eq 0 ] && return 0
  if [ "${a:-0}" -eq 1 ]; then
    tg_notify "✅ A2A心跳已恢复（此前连续失败 ${n} 次）。"
  fi
  echo "[$(ts)] sentry recovered (streak was $n, alerted=${a:-0})" >> "$LOG"
  streak_set 0 0
}

# --- 0) 冷却检查 ---
if [ -f "$COOLDOWN_FILE" ]; then
  LAST=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ $((NOW - LAST)) -lt "$COOLDOWN_SECS" ]; then
    exit 0
  fi
fi

# --- 1) 探测 ---
SIGNAL_LINE="$(bash "$SENTRY")"
RC=$?

case "$RC" in
  0)
    on_ok
    exit 0
    ;;
  10)
    on_ok
    SIGNAL="$(printf '%s\n' "$SIGNAL_LINE" | grep '^SENTRY_SIGNAL=' | sed 's/^SENTRY_SIGNAL=//')"
    echo "[$(ts)] SIGNAL detected → waking agent: $SIGNAL" >> "$LOG"
    date +%s > "$COOLDOWN_FILE"
    bash "$WAKE" "$SIGNAL" >> "$LOG" 2>&1
    WRC=$?
    echo "[$(ts)] wake finished rc=$WRC" >> "$LOG"
    ;;
  *)
    echo "[$(ts)] sentry error rc=$RC" >> "$LOG"
    on_fail "$RC"
    exit "$RC"
    ;;
esac

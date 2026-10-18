#!/bin/bash
# ============================================================
# A2A心跳链路 一键安装 / 自检
# 用法：
#   1) cp config.example.sh config.sh  → 改里面的参数
#   2) bash install.sh                 → 装 cron + 自检
#   可选：bash install.sh --dry        → 只自检，不动 cron
# ============================================================
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

echo "==> 目录：$DIR"

# --- 0) 配置检查 ---
if [ ! -f "$DIR/config.sh" ]; then
  echo "!! 缺少 config.sh —— 请先：cp config.example.sh config.sh 然后编辑"
  exit 1
fi
# shellcheck disable=SC1091
. "$DIR/config.sh"

CLAWDCHAT_HOME="${CLAWDCHAT_HOME:-$HOME/.clawdchat}"
mkdir -p "$CLAWDCHAT_HOME"

echo "==> 依赖检查"
for b in bash curl python3; do
  command -v "$b" >/dev/null 2>&1 && echo "   ok  $b" || { echo "   !!  缺 $b"; exit 1; }
done
[ -x "$PICOCLAW_BIN" ] || command -v "$PICOCLAW_BIN" >/dev/null 2>&1 \
  && echo "   ok  picoclaw ($PICOCLAW_BIN)" || echo "   !!  picoclaw 不可执行：$PICOCLAW_BIN"

# --- 1) 凭证检查 ---
if [ ! -f "$CRED" ]; then
  echo "!! 缺少凭证 $CRED"
  echo "   格式：[{\"api_key\":\"clawdchat_xxx\",\"agent_name\":\"your-name\"}]"
  exit 1
fi
KEY=$(python3 -c "import json;print(json.load(open('$CRED'))[0]['api_key'])" 2>/dev/null)
[ -n "$KEY" ] && echo "   ok  凭证 api_key 已读取" || { echo "   !!  凭证解析失败"; exit 1; }

echo "==> 验证 ClawdChat 连通 + 账号状态"
curl -s -m 15 "$CLAWDCHAT_API/api/v1/me" -H "Authorization: Bearer $KEY" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);a=d.get('agent') or d;print('   ok  ',a.get('slug'),'/',a.get('name'),'| unread =',d.get('unread_total'))" \
  2>/dev/null || echo "   !! 状态查询失败（检查 api_key / 网络）"

# --- 1.5) 🔒 白名单自检 ---
echo "==> 🔒 聊天白名单自检"
bash -n "$DIR/config.sh" 2>/dev/null || { echo "   !! config.sh 语法错误"; exit 1; }
if [ -z "${CHAT_ALLOWLIST//[[:space:]]/}" ]; then
  echo "   ⚠️  CHAT_ALLOWLIST 为空 = 不限制（会回复任何私信你的人，有泄密风险！）"
  echo "       强烈建议在 config.sh 里设置名单，见 WHITELIST.md"
else
  echo "   ok  生效名单 = [ $CHAT_ALLOWLIST ]"
  echo "       名单外处置 NON_ALLOWLIST_POLICY = ${NON_ALLOWLIST_POLICY:-alert}"
fi

# --- 2) 脚本可执行 ---
chmod +x "$DIR"/clawdchat_*.sh "$DIR"/a2a_send.sh 2>/dev/null
echo "==> 脚本权限已设置"

# --- 3) 安装 cron ---
CRON_LINE="*/${POLL_EVERY_MIN:-5} * * * * $DIR/clawdchat_poll.sh >> $CLAWDCHAT_HOME/poll.log 2>&1"
if [ "$DRY" = "1" ]; then
  echo "==> [dry] 将写入 cron：$CRON_LINE"
else
  if crontab -l 2>/dev/null | grep -Fq "$DIR/clawdchat_poll.sh"; then
    echo "==> cron 已存在，跳过"
  else
    ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
    echo "==> cron 已安装：$CRON_LINE"
  fi
fi

# --- 4) 自检 ---
echo "==> 自检：sentry 无变化路径"
bash "$DIR/clawdchat_sentry.sh" >/dev/null 2>&1; echo "   sentry rc=$? (0/10 都正常)"

echo "==> 自检：poll 空跑（无信号应静默）"
bash "$DIR/clawdchat_poll.sh"; echo "   poll rc=$?"

# --- 4.5) ✍️ 签名自检（可选）---
echo "==> ✍️ 消息签名自检"
if [ -x "$DIR/a2a_send.sh" ]; then
  if [ -f "${A2A_SIGN_PY:-$HOME/.a2a/sign.py}" ] && [ -f "${A2A_KEYFILE:-$HOME/.a2a/ed25519.seed}" ]; then
    "$DIR/a2a_send.sh" --dry __selfcheck__ "selfcheck" >/dev/null 2>&1
    rc=$?
    case "$rc" in
      0) echo "   ok  签名可用（clock 自检通过）" ;;
      2) echo "   ⚠️  时钟偏差超限，签名发送会被中止 —— 请检查 NTP 对时" ;;
      *) echo "   ⚠️  签名自检 rc=$rc（工具/私钥异常；兼容期可回落裸 POST）" ;;
    esac
  else
    echo "   ⚠️  未配置签名（缺 sign.py / 私钥 seed）—— 兼容期可裸 POST；见 README §9"
  fi
else
  echo "   ⚠️  a2a_send.sh 不可执行"
fi

# --- 5) 🔒 白名单离线测试（可选，需要 mock；不碰生产接口）---
if [ -x "$DIR/tests/run_tests.sh" ]; then
  echo "==> 🔒 白名单逻辑离线测试（mock /home，隔离配置）"
  bash "$DIR/tests/run_tests.sh" && echo "   ✅ 白名单测试全绿" || echo "   ❌ 白名单测试有失败项"
fi

echo "==> 完成。日志：$CLAWDCHAT_HOME/{sentry,poll}.log"
echo "    白名单机制说明：$DIR/../../docs/CLIENT.md"

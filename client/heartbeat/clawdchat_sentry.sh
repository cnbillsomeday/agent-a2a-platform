#!/bin/bash
# ============================================================
# A2A哨兵探针（sentry）—— 可移植版
# 纯 shell + ETag 探测 /home：
#   无变化   → HTTP 304 → 静默退出（rc=0，零 LLM 成本）
#   有变化但无可回应内容 → rc=0（静默）
#   有需回应信号（默认仅「私信/消息」）→ rc=10 + 输出 SENTRY_SIGNAL={json}
#   错误     → rc=1/2
# 依赖：bash、curl、python3
# ============================================================
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"

CRED="${CRED:-$HOME/.clawdchat/credentials.json}"
STATE="${STATE:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/sentry-state.json}"
LOG="${LOG:-${CLAWDCHAT_HOME:-$HOME/.clawdchat}/sentry.log}"
API="${CLAWDCHAT_API:-http://127.0.0.1:21220}/api/v1/home"
# did:web 的主机名（反代/NAT 时与 API 主机名不同）；下面 python 从环境读取
A2A_DID_HOST="${A2A_DID_HOST:-}"
export A2A_DID_HOST

mkdir -p "$(dirname "$STATE")"

KEY=$(python3 -c "import json;print(json.load(open('$CRED'))[0]['api_key'])" 2>/dev/null)
[ -z "$KEY" ] && { echo "[$(date '+%F %T')] ERR no api_key ($CRED)"; exit 1; }

# ---- 🔒 聊天白名单（硬底线）----
# 只有名单内 agent 的私信/互动会触发「唤醒回复」；名单外一律不回复，
# 只给主人发一条告警（不惊动 LLM）。CHAT_ALLOWLIST 为空/未设 → 不限制（向后兼容）。
CHAT_ALLOWLIST="${CHAT_ALLOWLIST:-}"
# 名单外处理策略：alert=标记已读+Telegram 告警；silent=标记已读、静默不告警（默认 alert）
NON_ALLOWLIST_POLICY="${NON_ALLOWLIST_POLICY:-alert}"
TG_TOKEN="$(cat "${CLAWDCHAT_HOME:-$HOME/.clawdchat}/.tg_token" 2>/dev/null || true)"
TG_CHAT="${NOTIFY_CHAT_ID:-}"

LAST_ETAG=""
if [ -f "$STATE" ]; then
  LAST_ETAG=$(python3 -c "import json;print(json.load(open('$STATE')).get('etag',''))" 2>/dev/null)
fi

HDR=$(mktemp); BODY=$(mktemp)
CODE=$(curl -s -o "$BODY" -D "$HDR" -w "%{http_code}" "$API" \
  -H "Authorization: Bearer $KEY" \
  ${LAST_ETAG:+-H "If-None-Match: $LAST_ETAG"})

NEW_ETAG=$(grep -i '^etag:' "$HDR" | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//')

if [ "$CODE" = "304" ]; then
  echo "[$(date '+%F %T')] 304 no-change" >> "$LOG"
  rm -f "$HDR" "$BODY"; exit 0
fi

if [ "$CODE" != "200" ]; then
  echo "[$(date '+%F %T')] ERR http=$CODE" >> "$LOG"
  rm -f "$HDR" "$BODY"; exit 2
fi

# 200 = 有变化 → 分析内容
python3 - "$BODY" "$STATE" "$NEW_ETAG" "$LOG" "$CHAT_ALLOWLIST" "$KEY" "$CLAWDCHAT_API" "$TG_TOKEN" "$TG_CHAT" "$WAKE_SIGNALS" "$NON_ALLOWLIST_POLICY" <<'PYEOF'
import json, sys, datetime, urllib.request, urllib.parse, os
(body_path, state_path, etag, log, allowlist, key,
 api_base, tg_token, tg_chat, wake_signals, non_allowlist_policy) = sys.argv[1:12]

# 名单外处理策略：silent = 标记已读、静默不告警；其余（含 alert/空）= 告警
silent_block = (non_allowlist_policy or "").strip().lower() == "silent"

# ⚙️ 唤醒信号类型（默认仅私信/消息）
wake_sig = set((wake_signals or "dm").split())

# 🔒 白名单：为空/未设 → 不限制（向后兼容）；否则只放行名单内 slug
allow = set(allowlist.split()) if allowlist.strip() else None

# did:web 的主机名默认取 API 基址；反代/NAT 场景可用 A2A_DID_HOST 覆盖
DID_HOST = (os.environ.get('A2A_DID_HOST') or '').strip() or urllib.parse.urlparse(api_base).netloc
DID_PREFIX = 'did:web:' + DID_HOST + ':agents:'

def sender_slug(m):
    """把发送者身份归一化成 slug（接受 dict 或纯字符串）。
    /home 的 sender_name 有时是 slug（source=dm），有时是 DID（source=relay）。
    只信任本站 DID 前缀；其它 did:web:<host> 保留原样（不匹配白名单 → 名单外，防冒充）。
    """
    if isinstance(m, str):
        raw = m.strip()
    else:
        raw = (m.get('sender_name') or m.get('sender_did') or '').strip()
    if raw.startswith(DID_PREFIX):
        return raw[len(DID_PREFIX):]
    if raw.startswith('did:'):
        return raw  # 非本站 DID：保留全串，绝不与白名单 slug 相等
    return raw

def http_get(url):
    # ⚠️ CF 会拦 python urllib 默认 UA（403/1010）→ 显式带 UA
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + key,
        "User-Agent": "clawdchat-heartbeat/1.0 (+curl)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def tg_send(text):
    if not (tg_token and tg_chat):
        return
    try:
        data = urllib.parse.urlencode({"chat_id": tg_chat, "text": text}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{tg_token}/sendMessage", data=data)
        urllib.request.urlopen(req, timeout=20)
    except Exception:
        pass

d = json.load(open(body_path))

# 🚫 自消息过滤：自己发给自己的消息（自检/探测/记录）不构成「待回应」信号，
# 否则每次自检都会白唤醒一次 LLM。本机 slug 取自 /home 的 agent.slug。
self_slug = ((d.get('agent') or {}).get('slug') or '').strip()
self_skipped = 0
self_unread = 0    # 自消息贡献的未读数（用于「不可归因」差额时剔除，避免自检自触发告警）
cand_unread = 0    # 候选未读「消息数」（不是会话数：一个会话两条未读要算 2，否则差额恒差 1）

notif = d.get('notifications') or {}
unread = d.get('unread_messages', {})
wtd = d.get('what_to_do') or []

json.dump({"etag": etag, "lastCheck": datetime.datetime.now().isoformat()},
          open(state_path, 'w'))

# ============================================================
# 统一成「候选未读私信」列表，兼容两种 /home 结构：
#   ① legacy（旧 clawdchat.ai 及 2026-10-17 前的自建平台）
#      unread_messages = {messages:[{sender_name,conversation_id,content}], dm_count, relay_count}
#   ② v2（2026-10-17 19:43 重建后的自建平台）
#      unread_messages = <int>；未读明细在 conversations[] 的 unread_count +
#      with_agent.slug + last_message / summary.last_message
# ============================================================
cands = []
if isinstance(unread, dict) and isinstance(unread.get('messages'), list):
    shape = 'legacy'
    for m in (unread.get('messages') or []):
        _sender = sender_slug(m)
        if self_slug and _sender == self_slug:
            self_skipped += 1
            self_unread += 1
            continue
        cands.append({
            'sender': _sender,
            'cid': m.get('conversation_id') or '',
            'content': (m.get('content') or '')[:150],
        })
        cand_unread += 1
    dm_total = unread.get('dm_count', 0) + unread.get('relay_count', 0)
else:
    shape = 'v2'
    for c in (d.get('conversations') or []):
        if (c.get('unread_count') or 0) <= 0:
            continue
        wa = c.get('with_agent') or {}
        if self_slug and (wa.get('slug') or '') == self_slug:
            self_skipped += 1          # 自己发给自己：标记为「无需回应」
            self_unread += (c.get('unread_count') or 1)
            continue
        lm = c.get('last_message') or {}
        content = (lm.get('body') or lm.get('content') or lm.get('text')
                   or (c.get('summary') or {}).get('last_message') or '')
        cands.append({
            'sender': sender_slug(wa.get('slug') or wa.get('name') or ''),
            'cid': c.get('id') or '',
            'content': (content or '')[:150],
        })
        cand_unread += (c.get('unread_count') or 1)
    dm_total = (unread if isinstance(unread, int)
                else (d.get('unread_total') or notif.get('unread_total') or len(cands)))

# ---- 「不可归因未读」告警（dave 2026-10-18 提的第四种装聋）----
# 平台侧 unread_total 与 conversations[].unread_count 同源（都数 messages 里 to==我 且未读），
# 所以差额理论恒为 0；哪天平台口径变了、出现「有未读但看不到是谁发的」，我们会因为
# 「宁可不回」而静默到底。这里改成：不回复（安全），但**吵一次**，恢复后清标记。
delta = max(0, int(dm_total or 0) - int(cand_unread or 0) - int(self_unread or 0))
uatt_flag = state_path + '.unattrib'

# v6.1(F)：delta 一出现，就把「对账面」整段落进日志，事后不必靠猜。
# 只记 slug / 会话 id 后 6 位 / unread_count / shape，不含正文，也不放大消息体积。
def _uatt_detail():
    try:
        rows = []
        for c in (d.get('conversations') or []):
            uc = c.get('unread_count') or 0
            if uc <= 0:
                continue
            sl = ((c.get('with_agent') or {}).get('slug')
                  or (c.get('with_agent') or {}).get('name') or '?')
            rows.append('{}{}={}'.format('*' if sl == self_slug else '', sl, uc))
        top = d.get('unread_total')
        if top is None:
            top = notif.get('unread_total')
        return 'shape={} top={} dm_total={} cand={} self={} mine={} all={}'.format(
            shape, top, dm_total, cand_unread, self_unread, self_skipped,
            ' '.join(rows) or '-')
    except Exception as _e:
        return 'detail-error={!r}'.format(_e)
try:
    if delta > 0:
        if not os.path.exists(uatt_flag):
            tg_send("🦐 A2A：有未读但看不到来源（总数 {} / 可归因 {}，差 {} 条）。"
                    "已按「宁可不回」处理、未做任何回复。若反复出现，多为平台未读口径变化，"
                    "建议跑 a2a-selfcheck.sh 第 5 段确认。".format(dm_total, cand_unread, delta))
            open(uatt_flag, 'w').write(str(dm_total))
            with open(log, 'a') as _lf:
                _lf.write("[{}] UNATTRIB {}/{} delta={} alerted (no reply) convs={} | {}\n".format(
                    datetime.datetime.now().strftime('%F %T'), dm_total, cand_unread, delta, len(cands),
                    _uatt_detail()))
        else:
            with open(log, 'a') as _lf:
                _lf.write("[{}] UNATTRIB {}/{} delta={} already-alerted convs={} | {}\n".format(
                    datetime.datetime.now().strftime('%F %T'), dm_total, cand_unread, delta, len(cands),
                    _uatt_detail()))
    elif os.path.exists(uatt_flag):
        os.remove(uatt_flag)
        with open(log, 'a') as _lf:
            _lf.write("[{}] UNATTRIB cleared（恢复可归因）| {}\n".format(
                datetime.datetime.now().strftime('%F %T'), _uatt_detail()))
except Exception as _e:                      # 告警失败绝不影响主流程
    try:
        with open(log, 'a') as _lf:
            _lf.write("[{}] UNATTRIB handling error: {!r}\n".format(
                datetime.datetime.now().strftime('%F %T'), _e))
    except Exception:
        pass

# ---- 按发送者分「名单内 / 名单外」----
allowed_dm = 0
blocked = []
for c in cands:
    if allow is None or c['sender'] in allow:
        allowed_dm += 1
    else:
        blocked.append((c['sender'], c['content'], c['cid']))

# 名单外私信：GET 对话详情（=标记已读，防每 5 分钟反复触发）
# 策略 silent → 静默不告警；否则（alert）→ 给主人发一条告警。绝不回复。
if blocked:
    for sender, content, cid in blocked:
        if cid:
            try:
                http_get(f"{api_base}/a2a/conversations/{cid}")
            except Exception:
                pass
    names = "、".join(sorted(set(s for s, _, _ in blocked)))
    if not silent_block:
        tg_send("🦐 A2A底线拦截：收到「白名单外」的私信，已标记已读、未作任何回复。\n"
                f"来自：{names}\n条数：{len(blocked)}")
    open(log, 'a').write(
        f"[{datetime.datetime.now():%F %T}] BLOCKED non-allowlist DM from {names} ({len(blocked)})"
        f" policy={'silent' if silent_block else 'alert'} shape={shape}\n")

# 回退：未读总数若大于可归因条数（截断/缺明细），差额一律不纳入「可回复」信号
# （宁可不回，不可乱回）。allowed_dm 只统计可归因部分。
if allow is not None and dm_total > len(cands):
    allowed_dm = min(allowed_dm, len(cands))

# ---- 通知类：@提及/评论/关注（legacy 用 breakdown，v2 用 unread_* 字段）----
bd = notif.get('breakdown') or {}
mention = bd.get('mention', 0) or notif.get('unread_mentions', 0) or 0
comment = bd.get('comment', 0) or notif.get('unread_comments', 0) or 0
follow  = bd.get('follow', 0)  or notif.get('unread_follows', 0)  or 0

# 未启用的信号类型一律清零（不计入 signal，也就不会唤醒/通知）
if 'mention' not in wake_sig: mention = 0
if 'comment' not in wake_sig: comment = 0
if 'follow' not in wake_sig: follow = 0

signal = []
if allowed_dm: signal.append(f"私信/消息 {allowed_dm}")
if mention: signal.append(f"@提及 {mention}")
if comment: signal.append(f"评论 {comment}")
if follow: signal.append(f"关注 {follow}")

ts = datetime.datetime.now().strftime('%F %T')
if signal:
    line = f"[{ts}] SIGNAL " + " | ".join(signal) + f" shape={shape} self_skipped={self_skipped}"
    print(line)
    open(log, 'a').write(line + "\n")
    print("SENTRY_SIGNAL=" + json.dumps({
        "shape": shape,
        "dm": allowed_dm, "relay": 0, "mention": mention,
        "comment": comment, "follow": follow, "what_to_do": wtd,
        "conversations": [c['cid'] for c in cands if c['cid']],
        "allowlist": sorted(allow) if allow is not None else []
    }, ensure_ascii=False))
    sys.exit(10)
else:
    open(log, 'a').write(
        f"[{ts}] 200 changed-but-no-actionable shape={shape} "
        f"unread_total={dm_total} attributable={len(cands)} blocked={len(blocked)} "
        f"self_skipped={self_skipped}\n")
    sys.exit(0)
PYEOF
RC=$?
rm -f "$HDR" "$BODY"
exit $RC

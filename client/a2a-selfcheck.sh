#!/usr/bin/env bash
# ============================================================
# a2a-selfcheck.sh —— A2A 客户端只读自检
#   不发送消息、不写盘（除你自己的临时目录外不落任何文件）、不打印任何秘密。
# 用法：
#   bash a2a-selfcheck.sh                # 基础自检
#   bash a2a-selfcheck.sh --log <路径>   # 附带日志体检（文件或目录；目录取最新的 *.log）
#   bash a2a-selfcheck.sh --quiet        # 只打印 WARN / FAIL
#   bash a2a-selfcheck.sh --send-probe   # 额外真发一条签名探测给自己（默认不发，见第 8 段）
# 可选环境变量：
#   CLAWDCHAT_HOME  凭据目录（默认 ~/.clawdchat）
#   A2A_KEYDIR      密钥目录（默认 $HOME/.a2a）
#   A2A_SIGN_PY     签名脚本（默认 $A2A_KEYDIR/sign.py）
#   A2A_KEYFILE     私钥文件（默认 $A2A_KEYDIR/ed25519.seed）
#   CLAWDCHAT_API   平台基址（默认 http://127.0.0.1:21220）
# 退出码：0=无 FAIL（可有 WARN）  2=有 FAIL  3=依赖/路径错误
#
# 检查项（每段一行 PASS/WARN/FAIL）：
#   1 凭据：找到 token 并识别形态（旧代 64 位 hex 会直接指出已作废）
#   2 连通 + 身份 + 平台签名模式
#   3 时钟偏差（签名时间窗 ±300s）
#   4 密钥一致性：本地私钥派生公钥 == did.json 的 #key-1
#   5 数据结构：home / conversations 字段形状（v2 字段缺失会被点名）
#   6 日志体检：动作/失败/唤醒配对/去重/轮转/失败连告警（需 --log）
#   7 正文空白静态扫描：发送路径上的 strip/trim 会让签名失配
#   8 --send-probe（可选）：真发一条「首空格+尾换行」的探测给自己
#
# 设计原则：
#   · 只读：除可选 --send-probe 外不产生任何请求副作用，不写平台数据
#   · 不打印秘密：token / 私钥只做形态与指纹判断
#   · 不静默假绿：用户给的 --log 路径不对时 FAIL + exit 3，绝不回退默认目录
#   · 判据只认驱动行（行首时间戳），agent 正文里的 401/403 不算失败
#
# 版本：v6.1（2026-10-18。v4/v5/v6 由多方回归测试共同打磨：
#   跨日志同分钟去重、rc 失败码白名单、真实未读取最大值、
#   START/END 唤醒配对、目录聚合、--send-probe 真发探测）
# ============================================================
set -u
START_MS=$(date +%s%3N 2>/dev/null || true)
case "${START_MS:-}" in ''|*[!0-9]*) START_MS="" ;; esac
START_EP=$(date +%s 2>/dev/null || echo 0)
trap 'rm -f /tmp/.a2a_selfcheck_home.$$ /tmp/.a2a_selfcheck_did.$$ 2>/dev/null' EXIT INT TERM

API="${CLAWDCHAT_API:-http://127.0.0.1:21220}"
UA="a2a-selfcheck/1.0"
HOMEDIR="${CLAWDCHAT_HOME:-$HOME/.clawdchat}"
KEYDIR="${A2A_KEYDIR:-$HOME/.a2a}"
[ -d "$KEYDIR" ] || KEYDIR="$HOME/.a2a"
SIGN_PY="${A2A_SIGN_PY:-$KEYDIR/sign.py}"
KEYFILE="${A2A_KEYFILE:-$KEYDIR/ed25519.seed}"
LOGPATH=""
LOG_EXPLICIT=0
LOG_BAD=0
QUIET=0
SEND_PROBE=0
SCRIPTS_ARG=""
HOURS="${A2A_WINDOW_HOURS:-24}"
SC_TZ="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOGPATH="${2:-}"; LOG_EXPLICIT=1; shift 2 ;;
    --scripts-dir|--scripts) SCRIPTS_ARG="$SCRIPTS_ARG ${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --utc) SC_TZ="utc"; shift ;;
    --local) SC_TZ="local"; shift ;;
    --send-probe) SEND_PROBE=1; shift ;;          # v6.1 D：真发一条探测（默认不发）
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（-h 看用法）"; exit 3 ;;
  esac
done
# v6.1：段编号随可选段浮动，避免 --send-probe 时出现「7/7」后面还有第 8 段
TOT=7
[ "$SEND_PROBE" = 1 ] && TOT=8
VER="v6.1"
case "$HOURS" in ''|*[!0-9]*) HOURS=24 ;; esac
if [ "$HOURS" -lt 1 ]; then HOURS=1; fi          # v5.1 frank P4：--hours 0 会制造必然假红
if [ "$HOURS" -gt 720 ]; then HOURS=720; fi
export HOURS SC_TZ

PASS=0; WARN=0; FAIL=0
c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'
ok()  { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  %sPASS%s %s\n' "$c_g" "$c_0" "$*"; }
wrn() { WARN=$((WARN+1)); printf '  %sWARN%s %s\n' "$c_y" "$c_0" "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$c_r" "$c_0" "$*"; }
inf() { [ "$QUIET" = 1 ] && return 0; printf '       %s\n' "$*"; }
hdr() { [ "$QUIET" = 1 ] || printf '\n-- %s\n' "$*"; }

HAVE_PY_TS=1
command -v curl >/dev/null 2>&1 || { echo "缺少依赖：curl（网络检查全部依赖它）"; exit 3; }
if ! command -v python3 >/dev/null 2>&1; then
  HAVE_PY_TS=""
  wrn "缺少 python3 → 降级运行：跳过依赖 python3 的检查（凭据/连通/时钟/密钥/结构），时间窗退为「全历史」"
fi

[ "$QUIET" = 1 ] || printf 'A2A 自检  %s\n' "$(date '+%F %T %Z')"
[ "$QUIET" = 1 ] || printf '平台: %s\n' "$API"
# v3：打印脚本自身指纹，方便多台机器/多人对照「我们跑的是不是同一版」
SELF_SHA=$(sha256sum "$0" 2>/dev/null | awk '{print $1}')
[ "$QUIET" = 1 ] || printf '版本: %s\n' "$VER"
{ [ "$QUIET" = 1 ] || { [ -n "${SELF_SHA:-}" ] && printf '脚本: %s  sha256=%s\n' "$(basename "$0")" "${SELF_SHA:0:16}"; }; }

# ------------------------------------------------ 1) 凭据
if [ -z "$HAVE_PY_TS" ]; then
  hdr "1-5/${TOT} 跳过（缺 python3）"
  inf "缺 python3：凭据解析、连通性、时钟、密钥一致性、结构体检都需要它 → 本次只跑 ${TOT} 段里的日志与静态扫描"
  TOKEN=""
  HOME_JSON=""
  MY_SLUG=""
  SIGN_MODE=""
else
hdr "1/${TOT} 凭据"
CRED=""
for f in "$HOMEDIR/credentials.json" "$HOME/.clawdchat/credentials.json" "$HOME/.a2a/credentials.json"; do
  [ -f "$f" ] && { CRED="$f"; break; }
done
if [ -z "$CRED" ]; then
  bad "找不到凭据文件（试过 $HOMEDIR/credentials.json 等）。用 CLAWDCHAT_HOME 指定目录"
  TOKEN=""
else
  # 兼容多种结构：递归找长度 >= 32 的 token/api_key 字段
  TOKEN=$(python3 - "$CRED" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
items = []
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            kl = k.lower()
            if isinstance(v, str) and len(v) >= 32 \
               and not any(x in kl for x in ("public", "priv", "sig", "seed", "hash")):
                if any(t in kl for t in ("api_key", "apikey", "token", "key")):
                    items.append((kl, v))
            walk(v)
    elif isinstance(o, list):
        for i in o:
            walk(i)
walk(d)
# 优先 api_key / token，其次其他 key；避免误取 public_key 之类的非秘密
items.sort(key=lambda kv: 0 if ("api_key" in kv[0] or "token" in kv[0]) else 1)
print(items[0][1] if items else "")
PY
)
  if [ -n "$TOKEN" ]; then
    ok "凭据：$CRED（token 长度 ${#TOKEN}，已隐藏）"
    # 凭据代际识别（v3）：本平台 2026-10-17 重建后 token 是 43 位 base64url；
    # 更早那批 64 位 hex 已全部作废 → 拿着它跑什么都 401，先换 token 再排查别的。
    case "${#TOKEN}" in
      64) printf '%s' "$TOKEN" | grep -qE '^[0-9a-fA-F]{64}$' && \
            wrn "凭据是 64 位 hex ＝ 平台重建（2026-10-17）之前的旧代 token，已全部作废 → 必然 401。先找管理员换新 token，别在别处找原因" ;;
      43) inf "凭据代际：43 位 base64url（当前代）" ;;
    esac
  else
    bad "凭据文件存在但找不到 token 字段：$CRED"
  fi
fi

# ------------------------------------------------ 2) 连通性 / 身份 / 签名模式
hdr "2/${TOT} 连通性与身份"
HOME_JSON=""
MY_SLUG=""
SIGN_MODE=""
if [ -n "$TOKEN" ]; then
  # grace③：单次网络抖动不该直接判 FAIL —— 000/超时/5xx 重试 3 次
  CODE=""; TRY=0
  while [ "$TRY" -lt 3 ]; do
    TRY=$((TRY+1))
    # frank P9：curl 连接失败时自己就输出 000 且退出码非 0，再 `|| echo 000` 会拼成 "000000"，
    # 下面 case 匹配不到 → 重试一次都不走，报出来的码还是 6 个 0。先取码再归一化。
    CODE=$(curl -s -m 15 -A "$UA" -o /tmp/.a2a_selfcheck_home.$$ -w '%{http_code}' \
      "$API/api/v1/home" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
    case "$CODE" in ''|*[!0-9]*) CODE=000 ;; esac
    case "$CODE" in
      000|5*|"") [ "$TRY" -lt 3 ] && { inf "第 $TRY 次连通失败（$CODE），1s 后重试…"; sleep 1; } ;;
      *) break ;;
    esac
  done
  [ "$TRY" -gt 1 ] && [ "$CODE" = "200" ] && inf "重试后成功（第 $TRY 次）"
  if [ "$CODE" = "200" ]; then
    HOME_JSON="/tmp/.a2a_selfcheck_home.$$"
    ok "GET /api/v1/home → 200"
    MY_SLUG=$(python3 - "$HOME_JSON" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])).get("agent") or {}
print(a.get("slug") or "?")
PY
)
    SIGN_MODE=$(curl -s -m 15 -A "$UA" "$API/api/v1/keys" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("sign_mode") or "?")
except Exception:
    print("?")')
    if [ "$SIGN_MODE" = "?" ]; then
      wrn "身份 slug=$MY_SLUG 已取到，但 /api/v1/keys 没给出签名模式（无法确认平台是否 strict）"
    else
      ok "身份 slug=$MY_SLUG　平台签名模式=$SIGN_MODE"
    fi
    [ "$SIGN_MODE" = "strict" ] && inf "提示：strict 下无签名发送一律 403（GET 不受影响）"
  elif [ "$CODE" = "401" ]; then
    bad "GET /api/v1/home → 401（token 失效：平台重建后旧 token 全部作废，需要换新）"
  else
    bad "GET /api/v1/home → $CODE（已试 $TRY 次；网络/平台问题，或 UA 被 CF 拦）"
  fi
else
  bad "无 token，跳过连通性检查"
fi

# ------------------------------------------------ 3) 时钟（签名时间窗 ±300s）
hdr "3/${TOT} 时钟偏差"
SRV_DATE=$(curl -s -m 10 -A "$UA" -D - -o /dev/null "$API/healthz" 2>/dev/null \
  | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
if [ -n "$SRV_DATE" ]; then
  SKEW=$(python3 - "$SRV_DATE" <<'PY'
import sys, time, email.utils
try:
    t = email.utils.parsedate_to_datetime(sys.argv[1]).timestamp()
    print(int(time.time() - t))
except Exception:
    print("")
PY
)
  if [ -n "$SKEW" ]; then
    if [ "${SKEW#-}" -le 60 ] 2>/dev/null; then ok "与平台时差 ${SKEW}s（签名窗口 ±300s）"
    elif [ "${SKEW#-}" -le 300 ] 2>/dev/null; then wrn "与平台时差 ${SKEW}s（接近 ±300s 上限，建议校时）"
    else bad "与平台时差 ${SKEW}s，超出 ±300s → 签名一律被判 stale 403"; fi
  else
    wrn "无法解析服务器 Date 头"
  fi
else
  wrn "拿不到服务器 Date 头（跳过）"
fi

# ------------------------------------------------ 4) 密钥一致性
hdr "4/${TOT} 密钥（本地私钥 vs did.json #key-1）"
LOCAL_PUB=""
if [ ! -f "$SIGN_PY" ]; then
  wrn "找不到签名脚本 $SIGN_PY（跳过；可用 A2A_SIGN_PY 指定）"
elif [ ! -f "$KEYFILE" ]; then
  wrn "找不到私钥 $KEYFILE（跳过；若你用平台托管 seed，跑 sign-setup.sh 领一次）"
else
  LOCAL_PUB=$(python3 "$SIGN_PY" pubkey --keyfile "$KEYFILE" 2>/dev/null | tr -d '\r\n')
  if [ -z "$LOCAL_PUB" ]; then
    bad "私钥 $KEYFILE 解析不出 32 字节 seed（文件可能已损坏）"
  else
    ok "本地公钥 $(printf '%s' "$LOCAL_PUB" | cut -c1-16)…"
    if [ -n "$MY_SLUG" ] && [ "$MY_SLUG" != "?" ]; then
      curl -s -m 15 -A "$UA" "$API/agents/$MY_SLUG/did.json" -o /tmp/.a2a_selfcheck_did.$$ 2>/dev/null
      VERDICT=$(python3 - "/tmp/.a2a_selfcheck_did.$$" "$LOCAL_PUB" <<'PY'
import base64, json, sys
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def b58d(s):
    n = 0
    for ch in s:
        n = n * 58 + B58.index(ch)
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\x00" * (len(s) - len(s.lstrip("1"))) + body
def keyof(vm):
    if vm.get("publicKeyJwk"):
        j = vm["publicKeyJwk"]
        if j.get("crv") == "Ed25519" and j.get("x"):
            v = j["x"]; return base64.urlsafe_b64decode(v + "=" * (-len(v) % 4))
    for f in ("publicKeyBase64Url", "publicKeyBase64"):
        if vm.get(f):
            v = vm[f]; return base64.urlsafe_b64decode(v + "=" * (-len(v) % 4))
    mb = vm.get("publicKeyMultibase") or ""
    if mb.startswith("z"):
        raw = b58d(mb[1:]); return raw[2:] if len(raw) == 34 else raw
    return b""
try:
    did = json.load(open(sys.argv[1]))
except Exception:
    print("ERR unreadable did.json"); raise SystemExit
want = sys.argv[2].strip()
vms = did.get("verificationMethod") or []
if not vms:
    print("ERR no verificationMethod"); raise SystemExit
k1 = ""
for vm in vms:
    if str(vm.get("id", "")).endswith("#key-1"):
        k1 = base64.urlsafe_b64encode(keyof(vm)).decode().rstrip("=")
        break
if not k1:
    k1 = base64.urlsafe_b64encode(keyof(vms[0])).decode().rstrip("=")
print(("SAME " if k1 == want else "DIFF ") + k1[:16] + "…")
PY
)
      case "$VERDICT" in
        SAME*) ok "did.json #key-1 与本地私钥一致" ;;
        DIFF*) bad "did.json #key-1 与本地私钥不一致（$VERDICT）→ 签名会被判 sig-mismatch；跑 sign-setup.sh 走 register 路线修复" ;;
        *) wrn "密钥比对失败：$VERDICT" ;;
      esac
    else
      wrn "没取到自己的 slug（第 2 段失败），无法核对 did.json #key-1（跳过一致性判断）"
    fi
  fi
fi

# ------------------------------------------------ 5) 数据结构体检（装聋检测）
hdr "5/${TOT} 数据结构体检（你按旧字段取数会不会永远看到 0）"
if [ -n "$HOME_JSON" ]; then
  SHAPE_OUT=$(python3 - "$HOME_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
conv = d.get("conversations") or []
has_conv = "conversations" in d
notif = d.get("notifications") or {}
old = d.get("unread_messages")
top = d.get("unread_total")
new_n = notif.get("unread_messages") if isinstance(notif.get("unread_messages"), int) else None
legacy_dm = old.get("dm_count") if isinstance(old, dict) else None
legacy_ml = len(old.get("messages") or []) if isinstance(old, dict) else None
conv_sum = sum((c.get("unread_count") or 0) for c in conv)

srcs = []
def add(label, v):
    if isinstance(v, int):
        srcs.append((label, v))
add("unread_total", top)
add("notifications.unread_messages", new_n)
add("unread_messages(int)", old if isinstance(old, int) else None)
add("unread_messages.dm_count", legacy_dm)
add("unread_messages.messages", legacy_ml)
if has_conv:
    add("会话合计", conv_sum)

print("字段: unread_messages=%s  notifications.unread_messages=%s  unread_total=%s  会话合计%s"
      % (("缺失" if old is None else ("对象" if isinstance(old, dict) else type(old).__name__)),
         ("缺失" if new_n is None else new_n),
         ("缺失" if top is None else top),
         (str(conv_sum) if has_conv else "缺失")))
if old is None:
    print("结构: v2（顶层无 unread_messages）→ 读旧字段必然恒 0，必须读 conversations[].unread_count 或 unread_total")
elif isinstance(old, dict):
    print("结构: legacy 对象（dm_count=%s relay_count=%s）" % (old.get("dm_count"), old.get("relay_count")))
else:
    print("结构: v2 计数（unread_messages 是 %s）" % type(old).__name__)

if not srcs:
    print("真实未读=未知（各来源都没有可用数值，不做装聋结论）")
    print("NO_DATA")
else:
    real = max(v for _, v in srcs)
    if len(set(v for _, v in srcs)) > 1:
        print("口径不一: " + "，".join("%s=%s" % (k, v) for k, v in srcs) + "  → 按最大值判定（按优先级取会掩盖装聋）")
    print("真实未读=%s" % real)
    if old is None and real > 0:
        print("DEAF_RISK")
PY
)
  [ "$QUIET" = 1 ] || printf '%s\n' "$SHAPE_OUT" | sed 's/^/       /'
  case "$SHAPE_OUT" in
    *NO_DATA*) wrn "取不到未读值（unread_total / notifications / 会话合计 全缺）→ 无法判断装聋风险，不当 PASS" ;;
    *DEAF_RISK*) wrn "v2 结构且当前有未读：若你的哨兵仍按旧字段取数，就是装聋状态（按上面字段自查你的代码）" ;;
    *) ok "结构体检无冲突" ;;
  esac
else
  wrn "无 /home 数据，跳过结构体检"
fi

fi   # 结束「缺 python3 时跳过 1-5」的分支

# ------------------------------------------------ 6) 日志体检
hdr "6/${TOT} 心跳日志体检"
# frank③a：路径规范化 —— `//.a2a/send.sh` 与 `/.a2a/send.sh` 是同一个文件，报告里只能出现一次
# 无 python3 也要能跑：路径规范化与脚本发现都改成纯 shell / find（grace 那台 Windows 就是没有 python3）
_fold_slash() {  # 折叠开头连续 /，再把所有 // 收成一个
  _p="$1"
  while : ; do case "$_p" in //*) _p="${_p#/}" ;; *) break ;; esac; done
  while : ; do case "$_p" in *//*) _p="${_p//\/\//\/}" ;; *) break ;; esac; done
  printf '%s' "$_p"
}

norm_list() {   # 参数：路径列表 → 折叠连续 /、去重、只留仍存在的文件
  _seen=" "
  for _raw in "$@"; do
    [ -n "$_raw" ] || continue
    _p=$(_fold_slash "$_raw")
    [ -f "$_p" ] || continue
    case "$_seen" in *" $_p "*) continue ;; esac
    _seen="$_seen$_p "
    printf '%s\n' "$_p"
  done
}

# frank③b / dave③：心跳脚本目录可指定，找不到就记「无法判定」，不拿「日志目录里没有脚本」当结论
SCRIPT_DIRS=()
for d in "$HOMEDIR" "$HOME/clawdchat-heartbeat" "$HOME/.picoclaw/workspace/clawdchat-heartbeat" "$KEYDIR"; do
  [ -d "$d" ] && SCRIPT_DIRS+=("$d")
done
for d in ${SCRIPTS_ARG:-}; do
  [ -d "$d" ] && SCRIPT_DIRS+=("$d")
done

discover_scripts() {
  for _root in "$@"; do
    [ -n "$_root" ] || continue
    [ -d "$_root" ] || continue
    _root=$(_fold_slash "$_root")
    find "$_root" -maxdepth 2 -type f \
      \( -name '*.sh' -o -name '*.bash' -o -name '*.js' -o -name '*.mjs' \
         -o -name '*.cjs' -o -name '*.py' -o -name '*.ps1' -o -name '*.psm1' \) \
      2>/dev/null
  done | while IFS= read -r _f; do
    case "$(basename "$_f")" in a2a-selfcheck.sh) continue ;; esac
    printf '%s\n' "$_f"
  done | sort -u
}

LOGFILES=()
if [ -n "$LOGPATH" ]; then
  if [ -d "$LOGPATH" ]; then
    while IFS= read -r f; do [ -n "$f" ] && LOGFILES+=("$f"); done < <(ls -t "$LOGPATH"/*.log 2>/dev/null | head -8)
    if [ "${#LOGFILES[@]}" -gt 0 ]; then
      inf "目录 $LOGPATH：聚合 ${#LOGFILES[@]} 个 *.log（最多 8 个；.log.N 归档不纳入统计）"
    else
      # v5.1 frank P2 / dave：显式指定的目录里一个 *.log 都没有 = 无法判定，不许静默回退拿默认目录的绿灯
      ARC=$(ls "$LOGPATH"/*.gz "$LOGPATH"/*.log.* "$LOGPATH"/*.1 2>/dev/null | head -3)
      if [ -n "$ARC" ]; then
        bad "--log 指定的目录里没有 *.log：$LOGPATH（只有归档件未参与统计：$(printf '%s ' $ARC | sed 's#.*/##g')）→ 无法判定；未回退默认目录"
        inf "需要的话先解开再测：gzip -dc sentry.log.1.gz > /tmp/sentry.log，然后 --log /tmp/sentry.log"
      else
        bad "--log 指定的目录里没有 *.log：$LOGPATH（无法判定；未回退默认目录）"
      fi
      LOG_BAD=1
    fi
  elif [ -f "$LOGPATH" ]; then
    LOGFILES=("$LOGPATH")
  else
    # v5.1 frank P1 / dave：路径拼错或挂载没起时，回退默认目录会拿旧结果冒充新结果
    bad "--log 指定的路径不存在：$LOGPATH（无法判定；未回退默认目录）"
    LOG_BAD=1
  fi
fi
if [ "${#LOGFILES[@]}" -eq 0 ] && [ "$LOG_BAD" = 0 ]; then
  while IFS= read -r f; do [ -n "$f" ] && LOGFILES+=("$f"); done < <(ls -t "$HOMEDIR"/*.log 2>/dev/null | head -8)
fi
if [ "${#LOGFILES[@]}" -gt 0 ]; then
  DEDUP=$(norm_list "${LOGFILES[@]}")
  LOGFILES=()
  while IFS= read -r f; do [ -n "$f" ] && LOGFILES+=("$f"); done <<< "$DEDUP"
fi
[ "${#LOGFILES[@]}" -gt 0 ] && SCRIPT_DIRS+=("$(dirname "${LOGFILES[0]}")")
# v6.1：日志目录默认就是 HOMEDIR，append 后会出现同一个目录两次（只影响显示与 find 重复遍历）
if [ "${#SCRIPT_DIRS[@]}" -gt 0 ]; then
  _sd=""; _sd2=()
  for _d in "${SCRIPT_DIRS[@]}"; do
    case " $_sd " in *" $_d "*) continue ;; esac
    _sd="$_sd $_d"; _sd2+=("$_d")
  done
  SCRIPT_DIRS=("${_sd2[@]}")
fi
SCRIPTS=()

if [ "$LOG_BAD" = 1 ]; then
  printf '\n结果：PASS=%d WARN=%d FAIL=%d（--log 输入不可用：日志体检与静态扫描未执行）\n' "$PASS" "$WARN" "$FAIL"
  printf '判据：用户明确指定的输入不存在 = 无法判定，宁可红也不回退拿默认目录的绿灯。\n'
  exit 3
fi

if [ "${#LOGFILES[@]}" -eq 0 ]; then
  wrn "没找到日志（用 --log 指定你的心跳日志文件或目录）"
else
  # 体积/行数一律用 wc（frank②：BusyBox 没有 stat -c %s，原来会静默算成 0 字节 → 轮转检查永远通过）
  TOTB=0; TOTL=0; ROTBAD=""; EMPTY=""
  for f in "${LOGFILES[@]}"; do
    b=$(wc -c < "$f" 2>/dev/null | tr -d ' \t')
    l=$(wc -l < "$f" 2>/dev/null | tr -d ' \t')
    case "$b" in ''|*[!0-9]*) b=0 ;; esac
    case "$l" in ''|*[!0-9]*) l=0 ;; esac
    TOTB=$((TOTB + b)); TOTL=$((TOTL + l))
    if [ "$b" -eq 0 ]; then EMPTY="$EMPTY ${f}"; fi
    # frank 5：轮转命名可能是 .1 / .gz / .20261018，别只认 .1
    if [ "$b" -ge 5242880 ] && ! ls "$f".* >/dev/null 2>&1; then ROTBAD="$ROTBAD ${f}(${b}B)"; fi
  done
  inf "日志：$(printf '%s ' "${LOGFILES[@]}")"
  inf "合计 ${TOTB}B / ${TOTL} 行"
  if [ -n "$EMPTY" ]; then
    wrn "以下日志为 0 字节（路径错 / 探针没写 / 刚被清空 都会长这样）：$EMPTY"
  fi
  if [ -z "$ROTBAD" ]; then
    ok "各日志未超 5MB，或已有轮转（接受 .1 / .gz / 日期命名）"
  else
    wrn "以下日志超 5MB 且无任何轮转副本（只增不减）：$ROTBAD"
  fi

  # dave② / grace 备注：agent 正文日志不能靠「有没有时间戳」推断 —— agent 会把工具输出原样打出来，
  # 那些行同样带行首时间戳。判据改成三条并列：文件名 agent*.log、首行 marker、纯 prose（零驱动行）。
  AGENTBODY=""; DRIVEFILES=()
  for f in "${LOGFILES[@]}"; do
    base=$(basename "$f")
    # 显式 --log 指到轮转件（agent.log.1）时也按 agent 正文排除；只影响文件名判定，不影响统计范围
    case "$base" in
      *.log.[0-9]|*.log.[0-9][0-9]) base="${base%.*}" ;;
    esac
    case "$base" in
      agent.log|agent-*.log|agent_*.log|*agent-body*.log|*agentbody*.log) AGENTBODY="$AGENTBODY $f"; continue ;;
    esac
    if head -3 "$f" 2>/dev/null | grep -q 'A2A-AGENT-BODY'; then AGENTBODY="$AGENTBODY $f"; continue; fi
    d=$(awk 'match($0, /^[ \t]*\[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/){c++} END{print c+0}' "$f" 2>/dev/null)
    if [ "${d:-0}" -eq 0 ]; then AGENTBODY="$AGENTBODY $f"; continue; fi
    DRIVEFILES+=("$f")
  done
  [ -n "$AGENTBODY" ] && inf "已排除出动作/失败判据（agent 正文/应用日志，按文件名或首行 marker 判定）：$AGENTBODY"
  # v5.1 frank P6：未来时间戳会让「很久没动作」被算成「刚刚动过」，时钟跳变时静默变绿
  if [ "${#DRIVEFILES[@]}" -gt 0 ]; then
    NOWSTR=$(date '+%F %T'); [ "$SC_TZ" = "utc" ] && NOWSTR=$(date -u '+%F %T')
    FUT=0
    for f in "${DRIVEFILES[@]}"; do
      n=$(awk -v now="$NOWSTR" 'match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/){ ts = substr($0, RSTART, 19); gsub(/T/, " ", ts); if (ts > now) c++ } END { print c+0 }' "$f" 2>/dev/null)
      case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
      FUT=$((FUT + n))
    done
    if [ "$FUT" -gt 0 ]; then
      wrn "有 $FUT 行时间戳在将来（时钟/时区跳变会让日志一直「刚刚动过」，真实空档被掩盖）"
    fi
  fi

  # grace①：CUTOFF 用日志时区，默认本地墙钟，--utc 切 UTC，--hours N 改窗口；标签跟实际口径走
  WINDOW="全历史"; CUTOFF=""
  if [ -n "${HAVE_PY_TS:-}" ]; then
    CUTOFF=$(python3 - <<'PY'
import datetime, os
h = int(os.environ.get("HOURS", "24") or 24)
base = datetime.datetime.utcnow() if os.environ.get("SC_TZ", "local") == "utc" else datetime.datetime.now()
print((base - datetime.timedelta(hours=h)).strftime("%F %T"))
PY
)
  fi
  # grace② 后半：没有 python3 也要能截窗 —— date -d/@epoch（GNU/BusyBox）、date -r（BSD）、awk strftime
  if [ -z "$CUTOFF" ]; then
    _EP=$(awk -v h="$HOURS" 'BEGIN{ "date +%s" | getline t; close("date +%s"); printf "%d", t - h*3600 }' 2>/dev/null)
    case "${_EP:-}" in ''|*[!0-9]*) _EP="" ;; esac
    if [ -n "$_EP" ]; then
      if [ "$SC_TZ" = "utc" ]; then
        CUTOFF=$(date -u -d "@$_EP" '+%F %T' 2>/dev/null || date -u -r "$_EP" '+%F %T' 2>/dev/null || true)
      else
        CUTOFF=$(date -d "@$_EP" '+%F %T' 2>/dev/null || date -r "$_EP" '+%F %T' 2>/dev/null || true)
      fi
      if [ -z "$CUTOFF" ]; then
        CUTOFF=$(awk -v ep="$_EP" 'BEGIN{ s = strftime("%F %T", ep); if (s != "") print s }' 2>/dev/null || true)
      fi
    fi
    [ -n "$CUTOFF" ] && inf "python3 不可用，窗口基准改用 date/awk 计算"
  fi
  if [ -n "$CUTOFF" ]; then
    WINDOW="近 ${HOURS}h（≥ $CUTOFF，基准 $SC_TZ）"
  else
    WINDOW="全历史（取不到当前时间，未截窗；数字是全量口径）"
  fi

  if [ "${#DRIVEFILES[@]}" -eq 0 ]; then
    if [ -n "$AGENTBODY" ]; then
      inf "没有可统计的驱动日志（你指的日志全是 agent 正文/应用日志）→ 跳过动作与失败判据，不算故障，不报 WARN"
    else
      wrn "没有可统计的驱动日志 → 跳过动作与失败判据，避免假警报"
    fi
    inf "若这就是你的心跳日志，说明脚本没写带时间戳的驱动行；否则用 --log 指向 poll.log / wake.log"
  else
    # ⚠️ v4 统计口径（三次协作反馈合并）：
    #   ① 只认「行首时间戳」的驱动行（agent 正文里的 401/403 一律不算）
    #   ② 动作判据放宽到真实写法：SIGNAL / wake START / wake END / tg_notify / waking agent / ACTIONABLE（frank①）
    #   ③ 失败码不再穷举白名单：rc 非 0 且非 10（10=检出信号）就算失败（grace②，避开发送失败 rc=4 被当成功）
    #   ④ http=000 计入且单独标注网络层失败（frank②）；http 4xx/5xx 照旧
    #   ⑤ 同一事件跨日志只算一次：sentry 的 ERR http 与 poll 转述的 sentry error rc 按「分钟」配对去重（dave①）
    STATS=$(awk -v cutoff="$CUTOFF" '
      function badrc(v) { v = v + 0; return (v != 0 && v != 10) }
      {
        line = $0
        if (!match(line, /^[ \t]*\[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) next
        drv++
        ts = substr(line, RSTART, RLENGTH)
        sub(/^[ \t]*\[?/, "", ts)
        gsub(/T/, " ", ts)
        low = tolower(line)
        minute = substr(ts, 1, 16)
        # 动作判据：actionable 必须不是 no-actionable 里的后缀（dave①），wake failed 也是动作
        act = ((low ~ /signal|wake start|wake end|wake finished|wake failed|waking agent|tg_notify/) \
               || (low ~ /(^|[^a-z-])actionable/))
        err = 0; key = ""
        # ① 网络层失败：000 不再绑定 ERR 前缀（frank① / dave① / grace③）
        if (low ~ /(http|status)[ =:]?000([^0-9]|$)/) {
          err = 1; key = "n:" minute
        } else if (low ~ /err http=/) {
          c = line; sub(/.*[Ee][Rr][Rr] http=/, "", c); sub(/[^0-9].*/, "", c)
          err = 1; key = "h:" minute ":" c
        } else if (low ~ /(http|status)[ =:]?[45][0-9][0-9]/) {
          c = line; sub(/.*[Hh][Tt][Tt][Pp][ =:]/, "", c); sub(/[^0-9].*/, "", c)
          err = 1; key = "h:" minute ":" c
        } else if (low ~ /sentry error/) {
          err = 1; key = "s:" minute
        } else if (low ~ /client\.timeout|timed out|timeout exceeded/) {
          err = 1; key = "t:" minute
        }
        # ② 唤醒失败但没打 rc（进程崩溃/被杀/提前 return）也要算失败（frank②）
        if (!err && low ~ /wake failed|wake aborted|agent crashed|^[^\]]*abort:/) {
          err = 1; key = "f:" minute
        }
        # rc= 出现在任何驱动行都要判；该行已有 n/h/s/t/f 键时不再另起 w: 键（避免同一行数两次）
        if (!(err && key ~ /^[nstf]:/)) {
          n = split(line, Q, "rc=")
          for (i = 2; i <= n; i++) {
            v = Q[i]; sub(/[^0-9].*/, "", v)
            if (v != "" && badrc(v)) { err = 1; key = "w:" minute ":" v }
          }
        }
        if (act) actall++
        if (err) errall++
        if (cutoff != "" && ts < cutoff) {
          if (act && !(minute in oactm)) { oactm[minute] = 1; oact++ }
          if (err) eroldkey[key] = 1
          next
        }
        if (act) {
          actn++
          if (!(minute in actm)) { actm[minute] = 1; actev++ }
        }
        if (err) {
          # ③ 去重键带「种类+码」；同文件永不合并；sentry 转述只在跨文件时配对（frank③ / grace① / dave①）
          if (key ~ /^s:/ && (minute in hfile) && hfile[minute] != FILENAME) {
            dup++
          } else if (key in kf) {
            if (kf[key] != FILENAME) dup++
            else ev++
          } else {
            kf[key] = FILENAME; ev++
          }
          if (key ~ /^[nh]:/) hfile[minute] = FILENAME
          if (key ~ /^[wf]:/) waken++
          if (key ~ /^n:/) z000 = 1
          last = line
        }
      }
      END {
        # sentry 的 ERR 与 poll 转述的 sentry error 谁先读到都可能，顺序不能决定结果 → 收尾对账
        for (k in kf) {
          if (k ~ /^s:/) {
            mm = substr(k, 3)
            for (j in kf) {
              if (j ~ /^h:/ && substr(j, 3, 16) == mm && kf[j] != kf[k]) {
                if (!(k in srecon)) { srecon[k] = 1; ev--; dup++ }
                break
              }
            }
          }
        }
        eo = 0; for (k in eroldkey) eo++
        printf "DRV=%d\nACT=%d\nACTALL=%d\nACTEV=%d\nERR=%d\nERRALL=%d\nEROLD=%d\nZ000=%s\nWAKEBAD=%d\nDUP=%d\nLAST=%s\n", drv+0, actn+0, actall+0, actev+0, ev+0, errall+0, eo, (z000+0 ? "1" : "0"), waken+0, dup+0, last
      }
    ' "${DRIVEFILES[@]}" 2>/dev/null)

    st() { printf '%s\n' "$STATS" | sed -n "s/^$1=//p" | head -1; }
    DRV=$(st DRV); ACT=$(st ACT); ACTALL=$(st ACTALL); ACTEV=$(st ACTEV)
    ERR=$(st ERR); ERROLD=$(st ERROLD); Z000=$(st Z000); LASTERR=$(st LAST); DUP=$(st DUP)
    ACT=${ACT:-0}; ACTALL=${ACTALL:-0}; ERR=${ERR:-0}; ERROLD=${ERROLD:-0}
    PROSE=$((TOTL - ${DRV:-0}))
    [ "$PROSE" -gt 0 ] && inf "驱动行 ${DRV:-0} / 总行 ${TOTL}（已排除 agent 正文文件；同文件内无时间戳行也排除）"
    if [ "${ACT:-0}" -gt 0 ]; then
      ok "$WINDOW 有 ${ACT} 条动作记录（SIGNAL/wake/tg_notify），≈${ACTEV:-?} 个分钟段（同分钟多条归并，非事件数），链路有真实动作"
    elif [ "${ACTALL:-0}" -gt 0 ]; then
      wrn "$WINDOW 无动作记录，更早有 ${ACTALL} 条 —— 若最近确实收到过私信却没动，链路可能装聋"
    else
      wrn "日志里没有任何 SIGNAL/wake 记录 —— 若最近确实收到过私信，说明链路可能装聋"
      # A2 未采纳（只统计 *.log）：同目录的 .log.N 归档不参与统计，这里只提示，不影响判定
      ARCHN=0
      for _ad in "${SCRIPT_DIRS[@]}"; do
        for _af in "$_ad"/*.log.[0-9] "$_ad"/*.log.[0-9][0-9]; do
          [ -f "$_af" ] && ARCHN=$((ARCHN + 1))
        done
      done
      [ "$ARCHN" -gt 0 ] && inf "提示：同目录另有 $ARCHN 个 .log.N 归档未纳入统计（v6.1 起明确不读归档）；要看更早记录请显式 --log 指到某个归档文件"
    fi
    if [ "${ERR:-0}" -gt 0 ]; then
      wrn "$WINDOW 有 ${ERR} 条失败事件（同分钟跨日志已配对去重；rc=10 与 HTTP 200 不算失败），最后一条：$(printf '%s' "$LASTERR" | cut -c1-110)"
      [ "${Z000:-0}" = "1" ] && inf "其中含 http=000：网络层失败（连不上/DNS/TLS），不是鉴权问题，排查方向完全不同"
      [ "${DUP:-0}" -gt 0 ] && inf "同分钟跨日志已去重 ${DUP} 条（sentry 的 ERR 与 poll 转述的 sentry error rc 属同一事件）"
    else
      ok "$WINDOW 无失败痕迹（rc=10 有信号、HTTP 200 正常，均不计入）"
    fi
    [ "${ERROLD:-0}" -gt "${ERR:-0}" ] && inf "另有 $((ERROLD - ERR)) 个更早（窗口外）的失败事件，未计入"

    # v6.1 A1（frank P9）：只有 wake START、没有 wake END = 唤醒被 timeout 杀掉 / agent 崩 / 机器重启，
    # 那批未读大概率没处理完。旧判据只看「有动作 / 有 rc」→ 半截日志反而最像全绿。
    # 前提：唤醒单进程串行，一轮 = START → attempt… → END；重试在同一轮内闭合。
    # 两个容易误报的点，已在下面处理：
    #   ① 一笔收尾有两种措辞（wake END rc= / 旧版 wake finished rc=）→ 同一分钟去重
    #   ② 日志只保留最近一段，最老那轮 START 的 END 在文件开头之前 → 该 START 不判失败（算「被切走」）
    PAIRS=$(awk '
      match($0, /^[ \t]*\[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
        ts = substr($0, RSTART, RLENGTH); sub(/^[ \t]*\[?/, "", ts); gsub(/T/, " ", ts)
        low = tolower($0)
        if (low ~ /wake start/) {
          to = 600
          if (match(low, /timeout=[0-9]+/)) { to = substr(low, RSTART + 8, RLENGTH - 8) + 0; if (to <= 0) to = 600 }
          print "S|" ts "|" to "|1"
        } else if (low ~ /wake (end|finished)/ || (low ~ /wake (failed|aborted|crashed)/ && low !~ /retry in|attempt/)) {
          print "E|" ts "|0|2"
        }
      }' "${DRIVEFILES[@]}" 2>/dev/null | sort -t'|' -k2,2 -k4,4 | awk -F'|' '
      $1 == "S" { n++; s++; st[n] = $2; to[n] = $3; next }
      $1 == "E" {
        mm = substr($2, 1, 16)
        if (mm in emin) next
        emin[mm] = 1
        if (firstE == "") firstE = $2
        if (n > 0) { n--; e++; if ($2 > lastE) lastE = $2 } else oe++   # LIFO：闭合「最近的那个」START
        next
      }
      END {
        printf "S=%d\nE=%d\nOPEN=%d\nFIRSTE=%s\nLASTE=%s\nOE=%d\n", s+0, e+0, n+0, firstE, lastE, oe+0
        for (i = 1; i <= n; i++) printf "OPENL=%s|%s\n", st[i], to[i]
      }')
    pvn() { printf '%s\n' "$PAIRS" | sed -n "s/^$1=//p" | head -1; }
    PS=$(pvn S); PE=$(pvn E); POPEN=$(pvn OPEN); PFIRSTE=$(pvn FIRSTE); PLASTE=$(pvn LASTE); POE=$(pvn OE)
    case "${PS:-}" in ''|*[!0-9]*) PS=0 ;; esac
    case "${POPEN:-}" in ''|*[!0-9]*) POPEN=0 ;; esac
    case "${POE:-}" in ''|*[!0-9]*) POE=0 ;; esac
    if [ "$PS" -eq 0 ]; then
      inf "日志里没有 wake START 行（可能没记唤醒起点）→ START/END 配对检查跳过"
    elif [ "$POPEN" -eq 0 ]; then
      ok "唤醒配对：$PS 次 wake START 都有对应 wake END（没有半途被杀掉的）"
    else
      OPEN_REAL=0; OPEN_CUT=0; NEW_TS=""; NEW_TO=600
      while IFS='|' read -r _t _to; do
        [ -n "${_t:-}" ] || continue
        if [ -n "$PFIRSTE" ] && [ "$_t" \< "$PFIRSTE" ]; then OPEN_CUT=$((OPEN_CUT + 1)); continue; fi
        OPEN_REAL=$((OPEN_REAL + 1))
        if [ -z "$NEW_TS" ] || [ "$_t" \> "$NEW_TS" ]; then NEW_TS="$_t"; NEW_TO="$_to"; fi
      done < <(printf '%s\n' "$PAIRS" | sed -n 's/^OPENL=//p')
      case "${NEW_TO:-}" in ''|*[!0-9]*) NEW_TO=600 ;; esac
      if [ "$OPEN_REAL" -eq 0 ]; then
        ok "唤醒配对：$PS 次 wake START 全部闭合（$OPEN_CUT 个更早的 START 因日志开头被切走，无法配对，不计为故障）"
      else
        _LIM=$((NEW_TO + 60))
        _NOW=$(date +%s 2>/dev/null || echo "")
        _SEP=$(date -d "${NEW_TS:-}" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "${NEW_TS:-}" +%s 2>/dev/null || echo "")
        case "${_NOW:-}" in ''|*[!0-9]*) _NOW="" ;; esac
        case "${_SEP:-}" in ''|*[!0-9]*) _SEP="" ;; esac
        if [ -n "$_NOW" ] && [ -n "$_SEP" ]; then
          _AGE=$((_NOW - _SEP)); [ "$_AGE" -lt 0 ] && _AGE=0
          if [ -n "${PLASTE:-}" ] && [ "$NEW_TS" \< "$PLASTE" ]; then
            # 后面已经跑成过完整轮次 → 这是历史疤（如手工试验/旧脚本切换点），不是当前卡死
            wrn "有半截唤醒：START ${NEW_TS:-?}（声明 timeout=${NEW_TO}s）没有 END，但之后有过完整收尾（最近 ${PLASTE}）→ 链路已恢复；若那次是异常退出，看一眼当时的小结/agent.log"
          elif [ "$OPEN_REAL" -gt 1 ]; then
            bad "有 $OPEN_REAL 次 wake START 没等到 END（最近一次 ${NEW_TS:-?}，声明 timeout=${NEW_TO}s）：唤醒是单进程串行，不可能多轮同时在跑 → 至少一轮被 timeout 杀掉 / 崩溃 / 机器重启，那批未读大概率没处理完"
          elif [ "$_AGE" -gt "$_LIM" ]; then
            bad "最近一次 wake START（${NEW_TS:-?}，声明 timeout=${NEW_TO}s）没有对应 wake END，已超出 timeout 余量 $((_AGE - _LIM))s → 被 timeout 杀掉 / 进程崩 / 机器重启；那批未读大概率没处理完（连 rc 都没落，旧判据看不出来）"
          else
            ok "唤醒进行中（START ${NEW_TS:-?}，已 ${_AGE}s < timeout ${NEW_TO}s + 60s 宽限），暂不算故障"
          fi
        else
          wrn "有 wake START 没配对 wake END（最近一次 ${NEW_TS:-?}），但本机换算不了时间戳 → 无法判定是否已超时，请人工看一眼"
        fi
      fi
    fi
    [ "$POE" -gt 0 ] && inf "另有 $POE 条收尾找不到对应 START（轮转把开头切走了），未计入"

    # 时间区口径自检（grace①：日志写 UTC 而本机是 +08 时，窗口会整体偏移）
    if [ -n "${LASTERR:-}" ] && [ -n "${HAVE_PY_TS:-}" ]; then
      TZ_HINT=$(python3 - "$LASTERR" <<'PY'
import sys, re, datetime
m = re.search(r'(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})', sys.argv[1])
if not m:
    raise SystemExit
t = datetime.datetime.strptime(m.group(1) + ' ' + m.group(2), '%Y-%m-%d %H:%M:%S')
now = datetime.datetime.utcnow()
dl = abs((now - t).total_seconds())
du = abs((now - (t + datetime.timedelta(hours=8))).total_seconds())
if du + 3600 < dl and dl > 3 * 3600:
    print("UTC")
PY
)
      [ "${TZ_HINT:-}" = "UTC" ] && inf "提示：日志时间看起来是 UTC（与本地墙钟差约 8h）→ 用 --utc 校准窗口，别让窗口整体偏移"
    fi
  fi

  # dave③ / grace 备注：告警机制只认「脚本证据」，关键字出现在日志正文里不算（那是 agent 在叙述）
  SCRIPTS=()
  while IFS= read -r s; do [ -n "$s" ] && SCRIPTS+=("$s"); done < <(discover_scripts "${SCRIPT_DIRS[@]}")
  if [ -n "$SCRIPTS_ARG" ]; then
    inf "脚本扫描范围：--scripts-dir$(printf ' %s' $SCRIPTS_ARG) → 命中 ${#SCRIPTS[@]} 个"
  else
    inf "脚本扫描范围：未给 --scripts-dir → 用日志目录$(printf ' %s' "${SCRIPT_DIRS[@]}") → 命中 ${#SCRIPTS[@]} 个（想扫全可给多个 --scripts-dir）"
  fi
  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    inf "失败告警机制：无法判定（没找到心跳脚本；用 --scripts-dir 指定目录）"
  else
    HIT=$(grep -l -E 'FAIL_THRESHOLD|fail_streak|failStreak|FAIL streak|连续失败' "${SCRIPTS[@]}" 2>/dev/null \
      | grep -vE '/(tests?|spec)/|/(test|spec)[^/]*$' | head -3)
    [ -z "$HIT" ] && HIT=$(grep -l -E 'FAIL_THRESHOLD|fail_streak|failStreak|FAIL streak|连续失败' "${SCRIPTS[@]}" 2>/dev/null | head -3)
    if [ -n "$HIT" ]; then
      ok "心跳脚本里检测到失败连击/告警机制（$(printf '%s ' $HIT | sed 's/.*\///g')）"
    else
      wrn "扫了 ${#SCRIPTS[@]} 个脚本，未检测到失败连击告警 —— 探测连挂很久也不会通知你（建议：失败计数落盘，连续 6 次告警一次，恢复补一条）"
    fi
  fi
fi

# ------------------------------------------------ 7) 正文空白（尾换行 403）
hdr "7/${TOT} 正文空白（尾随换行 / 前导空格）"
inf "背景：2026-10-18 之前，平台在验签前对正文做了 trim，正文带首尾空白必 403；已修复为按原始字节验签。"
# grace③：与第 6 段共用脚本文件集（.sh/.js/.ps1…），扫 0 个文件时 WARN，不落 PASS
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  SCRIPTS=()
  while IFS= read -r s; do [ -n "$s" ] && SCRIPTS+=("$s"); done < <(discover_scripts "${SCRIPT_DIRS[@]}")
fi
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  wrn "没扫到任何脚本（$HOMEDIR / $HOME/clawdchat-heartbeat / $KEYDIR）→ 无法判定，不当 PASS（用 --scripts-dir 指定）"
else
  TRIM_RE='(content|body|msg|message|payload)[A-Za-z_]*[[:space:]]*\.(strip|trim)[[:space:]]*\(|TrimSpace\((content|body|msg)|(content|body|msg|message|payload)[A-Za-z_]*[[:space:]]*=[^=][^;]*\.(strip|trim)\(\)'
  CAT_RE='^[^:]+:[0-9]+:[[:space:]]*(export[[:space:]]+)?[A-Z_]*(CONTENT|BODY|MSG|MESSAGE|TEXT)[A-Z_]*=.*'
  TRIMHITS=$( {
      grep -n -E "$TRIM_RE" "${SCRIPTS[@]}" 2>/dev/null
      grep -n -E '\$\(cat [^)]*\)' "${SCRIPTS[@]}" 2>/dev/null | grep -E "$CAT_RE"
    } | grep -v 'a2a-selfcheck.sh' | head -4 )
  if [ -n "$TRIMHITS" ]; then
    wrn "发送/签名路径里有 trim 或 \$(cat) 取正文，正文末尾空行会被吃掉（不报错，只是内容与你写的不完全一致）"
    printf '%s\n' "$TRIMHITS" | while IFS= read -r l; do inf "  $l"; done
    inf "平台侧已兼容，不必急着改；只是别指望 bash 的 \$(...) 保留正文末尾空行（它一定会吃掉），需要就显式拼 \$'\\n'。"
  else
    ok "扫了 ${#SCRIPTS[@]} 个脚本，未发现「正文被 trim / 命令替换取正文」的写法"
  fi
fi
inf "验证方法：重跑 a2a-sign-setup.sh 的第 6 步——探测正文现在自带「前导空格 + 尾随换行」，能 200/sig_state=ok 即说明两端都按原始字节处理。"
inf "或者加 --send-probe 跑第 8 段：真发一条同样带空白的探测，直接看服务端回的 sig_state。"

# ------------------------------------------------ 8) 发送探针（可选）
if [ "$SEND_PROBE" = 1 ]; then
  hdr "8/${TOT} 发送探针（真发一条给自己）"
  inf "默认不做：脚本其余部分只读。这一段会 POST 一条消息，用来抓静态扫描抓不到的 403（空白被 trim / seed 被 retire / 公钥没登记）。"
  PROBE_TO="${SEND_PROBE_TO:-$MY_SLUG}"
  PROBE_TO="${PROBE_TO:-$MY_SLUG}"
  if [ -z "${TOKEN:-}" ]; then
    bad "发送探针需要可用 token（第 1 段没取到）→ 跳过"
  elif [ -z "${MY_SLUG:-}" ]; then
    bad "发送探针取不到自己的 slug（第 2 段 GET /home 失败）→ 跳过"
  elif [ ! -f "${SIGN_PY:-}" ] || [ ! -f "${KEYFILE:-}" ]; then
    bad "发送探针缺少签名工具（SIGN_PY=$SIGN_PY / KEYFILE=$KEYFILE）→ strict 下必 403；先跑一次 a2a-sign-setup.sh"
  else
    # 正文故意「前导空格 + 尾随换行」：既回归服务端 rawBody 验签，也回归自己有没有在发送前 trim
    PROBE_BODY=" [a2a-selfcheck 发送探针 $(date '+%F %T')] 首空格+尾换行；收到无需回复，sentry 已过滤自消息"$'\n'
    PROBE_JSON=$(python3 "$SIGN_PY" sign --keyfile "$KEYFILE" --from "$MY_SLUG" --to "$PROBE_TO" \
      --content "$PROBE_BODY" 2>/dev/null || true)
    if [ -z "$PROBE_JSON" ] || ! printf '%s' "$PROBE_JSON" | grep -q '"sig"'; then
      bad "签名失败（sign.py 报错或 seed 不可用）：$SIGN_PY --keyfile $KEYFILE"
    else
      PRESP=$(curl -s -m 30 -A "$UA" -w '\n__HTTP__%{http_code}' -X POST "$API/a2a/$PROBE_TO" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "$PROBE_JSON" 2>/dev/null || true)
      PCODE=$(printf '%s' "$PRESP" | sed -n 's/.*__HTTP__\([0-9]*\)$/\1/p')
      case "${PCODE:-}" in ''|*[!0-9]*) PCODE=000 ;; esac
      PBODY_R=$(printf '%s' "$PRESP" | sed 's/__HTTP__[0-9]*$//')
      case "$PCODE" in
        200|201)
          case "$PBODY_R" in
            *'"sig_state":"ok"'*) ok "发送探针：POST /a2a/$PROBE_TO → 200，sig_state=ok —— 说明服务端按原始字节验签（首空格+尾换行参与了签名），不是 trim 后再验" ;;
            *'"signed":false'*)   wrn "发送探针：200 但服务端未认签名（平台可能不是 strict，或请求没带签名）→ 正文已落库，属兼容期" ;;
            *)                    wrn "发送探针：200，但响应里没有 sig_state=ok（看不懂响应结构，人工看一眼）" ;;
          esac
          inf "副作用：给自己留了 1 条未读会话；sentry 已过滤自消息，不会触发唤醒，下轮自动清"
          inf "注：平台落库时会存 trim 后的正文（验签用的是原始字节），所以读回来的正文没有首尾空白属正常"
          ;;
        403)
          bad "发送探针：403 —— 验签被拒。优先查：① 正文首尾空白被自己 trim 了 ② seed 已被 retire 而公钥没登记 ③ 时钟偏差 >300s"
          ;;
        000)
          bad "发送探针：连不上（000）—— 网络/DNS/TLS 层问题，不是鉴权问题"
          ;;
        *)
          bad "发送探针：POST /a2a/$PROBE_TO → $PCODE（非 200）"
          [ -n "$PBODY_R" ] && inf "响应片段：$(printf '%s' "$PBODY_R" | cut -c1-160)"
          ;;
      esac
    fi
  fi
fi

# ------------------------------------------------ 收尾
rm -f /tmp/.a2a_selfcheck_home.$$ /tmp/.a2a_selfcheck_did.$$ 2>/dev/null
END_EP=$(date +%s 2>/dev/null || echo 0)
EL=0
case "${START_EP:-x}${END_EP:-x}" in
  *[!0-9]*) EL=0 ;;
  *) EL=$((END_EP - START_EP)); [ "$EL" -lt 0 ] && EL=0 ;;
esac
# v6.1：整秒粒度会把 1s 内的跑完显示成 0s，看着像没跑
END_MS=$(date +%s%3N 2>/dev/null || true)
ELMS=""
case "${START_MS:-}${END_MS:-}" in
  ''|*[!0-9]*) : ;;
  *) ELMS=$((END_MS - START_MS)); [ "$ELMS" -lt 0 ] && ELMS=0 ;;
esac
[ -n "$ELMS" ] && EL="${ELMS}ms" || EL="${EL}s"
if [ "$QUIET" = 1 ]; then
  # v6 frank P5：--quiet 只输出 WARN/FAIL 与结论行，脚本用这个当机器判据
  printf '结果：PASS=%d WARN=%d FAIL=%d ver=%s sha=%s 耗时=%s\n' "$PASS" "$WARN" "$FAIL" "$VER" "${SELF_SHA:-unknown}" "$EL" 2>/dev/null \
    || printf '结果：PASS=%d WARN=%d FAIL=%d 耗时=%s\n' "$PASS" "$WARN" "$FAIL" "$EL"
else
  [ "$WARN" -eq 0 ] || printf '\nWARN=%d\n' "$WARN"
  [ "$FAIL" -eq 0 ] || printf 'FAIL=%d\n' "$FAIL"
  printf '\n结果：PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
  printf '耗时：%s（网络抖动时部分检查会被跳过；明显偏长就重跑一次）\n' "$EL"
fi
if [ "$FAIL" -gt 0 ]; then
  [ "$QUIET" = 1 ] || printf '有 FAIL：优先处理上面标红项（尤其 401 / 密钥不一致 / 装聋风险）。\n'
  exit 2
fi
[ "$QUIET" = 1 ] || printf '无 FAIL。WARN 里若有「装聋风险」「无 SIGNAL 记录」「无失败告警」，建议照修。\n'
exit 0

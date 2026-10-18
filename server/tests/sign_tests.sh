#!/usr/bin/env bash
# 签名（方案二）回归测试：独立实例，不碰生产目录。
# 覆盖：strict 拒裸签 / 签名通过 / nonce 重放 / 正文篡改 / 时间窗 / 每 agent 独立公钥 /
#       sign.py 指纹 / redeem 一次性 / register 自持公钥 / warn 模式放行标记
set -u

BIN=${BIN:-$(cd "$(dirname "$0")/.." && pwd)/a2a-server}
SRC=${SRC:-$(cd "$(dirname "$0")/.." && pwd)}
PORT=${PORT:-21297}
PORT_W=${PORT_W:-21296}
TMP=$(mktemp -d /tmp/a2a-sign-tests.XXXXXX)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: actual [$2] expected [$3]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] !~ [$3]" ;; esac; }

cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
            [ -n "${PIDW:-}" ] && kill "$PIDW" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

# --- 起 strict 实例 ---
A2A_SIGN_MODE=strict "$BIN" -addr "127.0.0.1:$PORT" -dir "$TMP/s" -domain test.example >"$TMP/s.log" 2>&1 &
PID=$!
# --- 起 warn 实例 ---
A2A_SIGN_MODE=warn "$BIN" -addr "127.0.0.1:$PORT_W" -dir "$TMP/w" -domain test.example >"$TMP/w.log" 2>&1 &
PIDW=$!
for i in $(seq 1 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && \
  curl -fs -o /dev/null "http://127.0.0.1:$PORT_W/healthz" 2>/dev/null && break
  sleep 0.2
done
B="http://127.0.0.1:$PORT"
BW="http://127.0.0.1:$PORT_W"
UA="a2a-sign-tests/1.0"

tok() { awk -F'\t' -v s="$2" '$1==s{print $3}' "$1/tokens.txt"; }
TA=$(tok "$TMP/s" alice); TW=$(tok "$TMP/s" dave)
TAW=$(tok "$TMP/w" alice); TWW=$(tok "$TMP/w" dave)

post() { # post <base> <to> <token> <bodyfile>
  curl -s -m 10 -o "$TMP/resp.json" -w '%{http_code}' -X POST "$1/a2a/$2" \
    -H "Authorization: Bearer $3" -H "Content-Type: application/json" -A "$UA" --data-binary @"$4"
}

# 1) 每 agent 独立公钥
K1=$(curl -s "$B/agents/alice/did.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verificationMethod"][0]["publicKeyJwk"]["x"])')
K2=$(curl -s "$B/agents/dave/did.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verificationMethod"][0]["publicKeyJwk"]["x"])')
[ "$K1" != "$K2" ] && ok || bad "agent keys must differ ($K1 == $K2)"
eq "did key count" "$(curl -s "$B/agents/alice/did.json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["verificationMethod"]))')" "1"

# 2) sign.py 指纹端点与服务内容一致
S1=$(curl -s "$B/sign.py" | sha256sum | awk '{print $1}')
S2=$(curl -s "$B/sign.py.sha256" | awk '{print $1}')
eq "sign.py sha" "$S2" "$S1"

# 3) strict：裸 POST 403
echo '{"content":"unsigned hello"}' > "$TMP/plain.json"
eq "strict unsigned" "$(post "$B" dave "$TA" "$TMP/plain.json")" "403"

# 4) redeem
R=$(curl -s "$B/a2a/keys/redeem" -H "Authorization: Bearer $TA" -H "Content-Type: application/json" -d '{}')
echo "$R" > "$TMP/redeem.json"
contains "redeem first" "$R" '"first_redeem":true'
SEED=$(python3 -c 'import json,sys,base64;d=json.load(open(sys.argv[1]));print(base64.urlsafe_b64encode(base64.urlsafe_b64decode(d["seed_base64url"]+"="*(-len(d["seed_base64url"])%4))).decode().rstrip("="))' "$TMP/redeem.json")
python3 - "$TMP/redeem.json" "$TMP/k.seed" <<'PY'
import json, sys, base64
d = json.load(open(sys.argv[1]))
s = d["seed_base64url"]; raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
open(sys.argv[2], "wb").write(raw)
PY
R2=$(curl -s "$B/a2a/keys/redeem" -H "Authorization: Bearer $TA")
contains "redeem second not-first" "$R2" '"first_redeem":false'

# 5) 正确签名 -> 200 signed=true
msg() { python3 "$SRC/assets/sign.py" sign --keyfile "$TMP/k.seed" --from "$1" --to "$2" --content "$3" > "$4"; }
msg alice dave "signed hello 你好" "$TMP/signed.json"
CODE=$(post "$B" dave "$TA" "$TMP/signed.json")
eq "signed send" "$CODE" "200"
contains "signed flag" "$(cat "$TMP/resp.json")" '"signed":true'
contains "sig ok" "$(cat "$TMP/resp.json")" '"sig_state":"ok"'

# 6) 同 nonce 重放 -> 403
eq "replay" "$(post "$B" dave "$TA" "$TMP/signed.json")" "403"
contains "replay msg" "$(cat "$TMP/resp.json")" 'replayed nonce'

# 7) 篡改正文（新 nonce，旧签名）-> 403
python3 - "$TMP/signed.json" "$TMP/tampered.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["content"] += "（篡改）"; d["nonce"] = "deadbeef" * 4
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False)
PY
eq "tampered" "$(post "$B" dave "$TA" "$TMP/tampered.json")" "403"
contains "tampered msg" "$(cat "$TMP/resp.json")" 'sig'

# 8) 时间窗：900 秒前的签名 -> 403 stale（用独立 nonce，避免重放干扰）
python3 - "$TMP/k.seed" "$SRC/assets/sign.py" "$TMP/old.json" <<'PY'
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("sg", sys.argv[2])
sg = importlib.util.module_from_spec(spec); spec.loader.exec_module(sg)
seed = open(sys.argv[1], "rb").read()
ts = int(time.time()) - 900
nonce = "a1b2c3d4" * 4
p = sg.payload("alice", "dave", ts, nonce, "stale message")
json.dump({"content": "stale message", "timestamp": ts, "nonce": nonce, "sig": sg.sign(seed, p.encode())},
          open(sys.argv[3], "w"))
PY
eq "stale" "$(post "$B" dave "$TA" "$TMP/old.json")" "403"
contains "stale msg" "$(cat "$TMP/resp.json")" 'stale'

# 9) 跨收件人移植签名 -> 403（签名绑定 from|to）
python3 - "$TMP/signed.json" "$TMP/moved.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["nonce"] = "0f0f0f0f" * 4
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False)
PY
eq "portable sig" "$(post "$B" carol "$TA" "$TMP/moved.json")" "403"

# 10) register 自持公钥（新密钥对）后其签名可通过
python3 - "$TMP" "$SRC/assets/sign.py" <<'PY'
import importlib.util, os, sys
tmp = sys.argv[1]
spec = importlib.util.spec_from_file_location("sg", sys.argv[2])
sg = importlib.util.module_from_spec(spec); spec.loader.exec_module(sg)
seed = os.urandom(32)
open(os.path.join(tmp, "k2.seed"), "wb").write(seed)
pub = sg.b64url_encode(sg.publickey(seed))
open(os.path.join(tmp, "k2.pub"), "w").write(pub)
PY
R3=$(curl -s "$B/a2a/keys/register" -H "Authorization: Bearer $TW" -H "Content-Type: application/json" \
      -d "{\"public_key\":\"$(cat "$TMP/k2.pub")\"}")
contains "register ok" "$R3" '"success":true'
python3 "$SRC/assets/sign.py" sign --keyfile "$TMP/k2.seed" --from dave --to alice --content "自持密钥签名" > "$TMP/k2.json"
eq "self-held key sign" "$(post "$B" alice "$TW" "$TMP/k2.json")" "200"
contains "self-held sig ok" "$(cat "$TMP/resp.json")" '"sig_state":"ok"'

# 11) warn 模式：裸 POST 放行但标 unsigned；验签失败放行但 sig_state 非 ok
echo '{"content":"warn unsigned"}' > "$TMP/plain2.json"
eq "warn unsigned" "$(post "$BW" dave "$TAW" "$TMP/plain2.json")" "200"
contains "warn unsigned flag" "$(cat "$TMP/resp.json")" '"signed":false'
python3 - "$TMP/k2.seed" "$SRC/assets/sign.py" "$TMP/forged.json" <<'PY'
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("sg", sys.argv[2])
sg = importlib.util.module_from_spec(spec); spec.loader.exec_module(sg)
seed = open(sys.argv[1], "rb").read()
ts = int(time.time()); nonce = "c0ffee00" * 4
p = sg.payload("dave", "alice", ts, nonce, "forged as dave?")
json.dump({"content": "forged", "timestamp": ts, "nonce": nonce, "sig": sg.sign(seed, p.encode())},
          open(sys.argv[3], "w"))
PY
eq "warn bad sig accepted" "$(post "$BW" alice "$TWW" "$TMP/forged.json")" "200"
contains "warn bad sig state" "$(cat "$TMP/resp.json")" '"signed":false'

# 13) 正文首尾空白必须按**原始字节**验签（Carol 2026-10-18 报：服务端先 trim 再验签 → strict 下必 403）
NL_BODY=$'尾换行测试\n'
python3 "$SRC/assets/sign.py" sign --keyfile "$TMP/k.seed" --from alice --to dave --content "$NL_BODY" > "$TMP/nl.json"
eq "trailing newline signed" "$(post "$B" dave "$TA" "$TMP/nl.json")" "200"
contains "trailing newline sig ok" "$(cat "$TMP/resp.json")" '"sig_state":"ok"'

SP_BODY='  前后空格测试  '
python3 "$SRC/assets/sign.py" sign --keyfile "$TMP/k.seed" --from alice --to dave --content "$SP_BODY" > "$TMP/sp.json"
eq "surrounding spaces signed" "$(post "$B" dave "$TA" "$TMP/sp.json")" "200"
contains "spaces sig ok" "$(cat "$TMP/resp.json")" '"sig_state":"ok"'
CID_SP=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["conversation_id"])' "$TMP/resp.json")
STORED=$(curl -s "$B/a2a/conversations/$CID_SP" -H "Authorization: Bearer $TW" | python3 -c 'import json,sys;d=json.load(sys.stdin);m=d.get("messages") or [];print((m[-1].get("body") or "") if m else "")')
eq "spaces stored trimmed" "$STORED" '前后空格测试'

# 13b) 兼容「先 trim 再签名」的客户端：sign 的是 trim 后字节，发的却带空格
python3 - "$TMP/k.seed" "$SRC/assets/sign.py" "$TMP/trimsign.json" <<'PY'
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("sg", sys.argv[2])
sg = importlib.util.module_from_spec(spec); spec.loader.exec_module(sg)
seed = open(sys.argv[1], "rb").read()
ts = int(time.time()); nonce = "7a7a7a7a" * 4
p = sg.payload("alice", "dave", ts, nonce, "trim-sign compat")
json.dump({"content": "trim-sign compat   ", "timestamp": ts, "nonce": nonce,
           "sig": sg.sign(seed, p.encode())}, open(sys.argv[3], "w"))
PY
eq "trim-sign compat accepted" "$(post "$B" dave "$TA" "$TMP/trimsign.json")" "200"
contains "trim-sign compat ok" "$(cat "$TMP/resp.json")" '"sig_state":"ok"'

# 12) keys 状态视图
KJ=$(curl -s "$B/api/v1/keys" -H "Authorization: Bearer $TW")
contains "keys view" "$KJ" '"redeemed"'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
rm -rf "$TMP"

#!/usr/bin/env bash
# A2A server regression suite. Self-contained: starts two isolated instances
# (main + short-retention) on localhost and tears them down.
set -u

BIN=${BIN:-$(cd "$(dirname "$0")/.." && pwd)/a2a-server}
PORT=${PORT:-21299}
PORT2=${PORT2:-21298}
DOMAIN=test.example
TMP=$(mktemp -d /tmp/a2a-tests.XXXXXX)
PASS=0
FAIL=0
BODY=$TMP/body.json
HEAD=$TMP/head.txt

cleanup() {
  [ -n "${PID1:-}" ] && kill "$PID1" 2>/dev/null
  [ -n "${PID2:-}" ] && kill "$PID2" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }
has()  { if grep -qF -- "$2" "$3"; then ok; else bad "$1: missing [$2]"; fi; }

jget() { # jget <dotted.path>
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[2]))
except Exception:
    print("<nojson>"); sys.exit(0)
for k in sys.argv[1].split("."):
    if k == "": continue
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        print("<missing>"); sys.exit(0)
if isinstance(d, bool): print("true" if d else "false")
elif isinstance(d, (dict, list)): print(json.dumps(d))
else: print(d)
' "$1" "$BODY"
}

jlen() { # jlen <dotted.path to a list/object>
  python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if k == "": continue
    d = d[int(k)] if isinstance(d, list) else d[k]
print(len(d))
' "$BODY" "$1"
}

http() { # http METHOD PATH TOKEN [DATA] [EXTRA_HDR]
  local m=$1 p=$2 t=${3:-} d=${4:-} h=${5:-}
  local args=(-sS --max-time 8 -o "$BODY" -w '%{http_code}' -X "$m" "$BASE$p")
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$d" ] && args+=(-H 'Content-Type: application/json' --data-binary "$d")
  [ -n "$h" ] && args+=(-H "$h")
  curl "${args[@]}"
}

wait_up() {
  for _ in $(seq 1 50); do
    curl -fsS --max-time 1 "http://127.0.0.1:$1/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$TMP/main" "$TMP/ret"
"$BIN" -addr "127.0.0.1:$PORT" -dir "$TMP/main" -domain "$DOMAIN" >"$TMP/main.log" 2>&1 &
PID1=$!
wait_up "$PORT" || { echo "server failed to start"; cat "$TMP/main.log"; exit 1; }
BASE="http://127.0.0.1:$PORT"

TOK_BOB=$(awk -F'\t' '$1=="bob"{print $3}' "$TMP/main/tokens.txt")
TOK_CAROL=$(awk -F'\t' '$1=="carol"{print $3}' "$TMP/main/tokens.txt")
TOK_DAVE=$(awk -F'\t' '$1=="dave"{print $3}' "$TMP/main/tokens.txt")
[ -n "$TOK_BOB" ] && [ -n "$TOK_CAROL" ] && [ -n "$TOK_DAVE" ] && ok || bad "tokens.txt parsing"

# ---- public surface ----
c=$(http GET /healthz);            eq "healthz 200" 200 "$c"
eq "health status" ok "$(jget status)"
c=$(http GET /api/v1/home);        eq "home without token 401" 401 "$c"
c=$(http GET /api/v1/home "bad");  eq "home bad token 401" 401 "$c"
c=$(http GET /api/v1/agents);      eq "agent directory 200" 200 "$c"
eq "agent count" 4 "$(jget count)"
c=$(http GET /.well-known/did.json); eq "domain did 200" 200 "$c"
eq "domain did id" "did:web:$DOMAIN" "$(jget id)"
ACOUNT=$(jlen agents)
eq "domain did agent array length" 4 "$ACOUNT"
c=$(http GET /agents/bob/did.json); eq "agent did 200" 200 "$c"
eq "agent did id" "did:web:$DOMAIN:agents:bob" "$(jget id)"
DIDBODY=$(cat "$BODY")
MP=$(jget verificationMethod.0.publicKeyMultibase)
case "$MP" in z*) ok;; *) bad "publicKeyMultibase prefix: $MP";; esac
eq "jwk crv" Ed25519 "$(jget verificationMethod.0.publicKeyJwk.crv)"
c=$(http GET /agents/bob/agent-card.json); eq "agent card 200" 200 "$c"
eq "agent card did" "did:web:$DOMAIN:agents:bob" "$(jget did)"
c=$(http GET /agents/nobody/did.json); eq "unknown agent did 404" 404 "$c"
c=$(http GET /u/carol); eq "profile 200" 200 "$c"
eq "profile slug" carol "$(jget slug)"
c=$(http GET /heartbeat.md); eq "heartbeat 200" 200 "$c"
has "heartbeat auth hint" "Authorization: Bearer" "$BODY"
c=$(http GET /skill.md); eq "skill 200" 200 "$c"
c=$(http GET /style-guide.md); eq "style 200" 200 "$c"
for f in "$TMP/main/tokens.txt" "$TMP/main/tokens.json" "$TMP/main/keys.json" "$TMP/main/allowlist.json"; do
  eq "perm $(basename "$f")" 600 "$(stat -c %a "$f")"
done

# ---- send / unread / ETag ----
c=$(http POST /a2a/bob "$TOK_CAROL" '{"message":"你好，Bob"}')
eq "send carol->bob 200" 200 "$c"
eq "send success" true "$(jget success)"
MSGID=$(jget message_id); CONVID=$(jget conversation_id)
case "$MSGID" in m_*) ok;; *) bad "message id: $MSGID";; esac
case "$CONVID" in c_*) ok;; *) bad "conversation id: $CONVID";; esac

c=$(http GET /api/v1/home "$TOK_BOB"); eq "ul home 200" 200 "$c"
eq "ul unread 1" 1 "$(jget notifications.unread_total)"
eq "ul unread_total alias" 1 "$(jget unread_total)"
eq "ul conversations 1" 1 "$(jlen conversations)"
eq "conv id stable" "$CONVID" "$(jget conversations.0.id)"
eq "conv other" carol "$(jget conversations.0.with_agent.slug)"
eq "conv summary unread" 1 "$(jget conversations.0.summary.unread_count)"
eq "compat field agent.karma" 0 "$(jget agent.karma)"
eq "compat field agent.post_count" 0 "$(jget agent.post_count)"
eq "compat field new_posts" "[]" "$(jget new_posts)"
ETAG=$(curl -sS -D "$HEAD" -o /dev/null -H "Authorization: Bearer $TOK_BOB" "$BASE/api/v1/home" >/dev/null; grep -i '^etag:' "$HEAD" | tr -d '\r' | cut -d' ' -f2-)
[ -n "$ETAG" ] && ok || bad "missing ETag"
c=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK_BOB" -H "If-None-Match: $ETAG" "$BASE/api/v1/home")
eq "ETag 304" 304 "$c"

c=$(http GET "/api/v1/a2a/conversations/$CONVID" "$TOK_BOB")
eq "conv detail 200" 200 "$c"
eq "conv detail clears unread" 1 "$(jget unread_cleared)"
eq "conv detail message count" 1 "$(jlen messages)"
eq "conv detail body" "你好，Bob" "$(jget messages.0.content)"
eq "conv detail text alias" "你好，Bob" "$(jget messages.0.text)"
c=$(http GET /api/v1/home "$TOK_BOB"); eq "ul unread cleared" 0 "$(jget notifications.unread_total)"

# dual prefix + reply
c=$(http POST /api/v1/a2a/carol "$TOK_BOB" '{"content":"收到"}'); eq "send dual prefix 200" 200 "$c"
c=$(http GET /api/v1/a2a/conversations "$TOK_CAROL"); eq "carol conversations 200" 200 "$c"
eq "carol conversation id match" "$CONVID" "$(jget conversations.0.id)"
eq "carol you_initiated true" true "$(jget conversations.0.you_initiated)"
c=$(http GET /api/v1/home "$TOK_CAROL"); eq "carol unread 1" 1 "$(jget notifications.unread_total)"
c=$(http GET "/a2a/conversations/$CONVID?peek=1" "$TOK_CAROL"); eq "peek 200" 200 "$c"
eq "peek does not clear" 0 "$(jget unread_cleared)"
c=$(http GET /api/v1/home "$TOK_CAROL"); eq "carol unread after peek" 1 "$(jget notifications.unread_total)"
c=$(http GET "/a2a/conversations/$CONVID" "$TOK_CAROL"); eq "read 200" 200 "$c"
eq "read messages 2" 2 "$(jlen messages)"
c=$(http GET /api/v1/home "$TOK_CAROL"); eq "carol unread after read" 0 "$(jget notifications.unread_total)"

# ---- validation ----
c=$(http POST /a2a/nobody "$TOK_BOB" '{"message":"x"}'); eq "unknown recipient 403" 403 "$c"
has "403 error text" "recipient not in allowlist" "$BODY"
c=$(http POST /a2a/carol "$TOK_BOB" '{"message":"   "}'); eq "empty message 422" 422 "$c"
c=$(http POST /a2a/carol "$TOK_BOB" '' 'Content-Type:' ); eq "no content-type 415" 415 "$c"
c=$(curl -sS -o "$BODY" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK_BOB" --data-binary '{"message":"x"}' "$BASE/a2a/carol")
eq "no content-type 415 (raw)" 415 "$c"
c=$(http POST /a2a/carol "not-a-token" '{"message":"x"}'); eq "forged token 401" 401 "$c"
LONG=$(python3 -c 'print("a"*8001)')
c=$(http POST /a2a/bob "$TOK_BOB" "{\"message\":\"$LONG\"}"); eq "8001 chars 422" 422 "$c"
OKLEN=$(python3 -c 'print("a"*8000)')
c=$(http POST /a2a/bob "$TOK_BOB" "{\"message\":\"$OKLEN\"}"); eq "8000 chars 200" 200 "$c"
c=$(http GET /a2a/carol); eq "GET send path 404 (catch-all)" 404 "$c"
c=$(http GET /nope); eq "unknown path 404" 404 "$c"
has "404 json" '"error"' "$BODY"

# DID normalisation for recipient
c=$(http POST "/a2a/did:web:$DOMAIN:agents:dave" "$TOK_BOB" '{"message":"did form"}')
eq "recipient did form 200" 200 "$c"

# ---- secrets must never appear in DID docs ----
curl -sS "$BASE/agents/bob/did.json" -o "$BODY"
if grep -qF -- "$TOK_BOB" "$BODY"; then bad "token leaked in DID doc"; else ok; fi
if grep -qF -- "$(python3 -c 'import json;print(json.load(open("'"$TMP/main/keys.json"'"))["ed25519_seed_base64url"])')" "$BODY"; then bad "seed leaked in DID doc"; else ok; fi

# ---- retention (separate instance) ----
"$BIN" -addr "127.0.0.1:$PORT2" -dir "$TMP/ret" -domain "$DOMAIN" -retention 2s >"$TMP/ret.log" 2>&1 &
PID2=$!
wait_up "$PORT2" || bad "retention server failed to start"
BASE2="http://127.0.0.1:$PORT2"
TOK2=$(awk -F'\t' '$1=="carol"{print $3}' "$TMP/ret/tokens.txt")
TOK2UL=$(awk -F'\t' '$1=="bob"{print $3}' "$TMP/ret/tokens.txt")
curl -sS -o /dev/null -X POST -H "Authorization: Bearer $TOK2" -H 'Content-Type: application/json' --data-binary '{"message":"ephemeral"}' "$BASE2/a2a/bob"
SLEEP_BODY=$TMP/ret_body
curl -sS -H "Authorization: Bearer $TOK2UL" "$BASE2/api/v1/home" -o "$SLEEP_BODY"
N=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["unread_total"])' "$SLEEP_BODY")
eq "retention before expiry" 1 "$N"
sleep 3.2
curl -sS -H "Authorization: Bearer $TOK2UL" "$BASE2/api/v1/home" -o "$SLEEP_BODY"
N=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["unread_total"])' "$SLEEP_BODY")
eq "retention after expiry" 0 "$N"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

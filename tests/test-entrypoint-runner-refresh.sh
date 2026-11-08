#!/usr/bin/env bash
# tests/test-entrypoint-runner-refresh.sh
#
# Behavioural tests for the runner-refresh block in scripts/docker-entrypoint.sh
# (between "BEGIN runner-refresh" and "END runner-refresh"), run together with
# the real config-load block so the token that config-to-env sees is observable.
#
# Contract (Stage 1):
#   - the exchange POSTs {"token": "<orig>"} from a 0600 file, never in argv
#   - on 200 with a non-empty .token, config-to-env authenticates with the
#     fresh token, while the app-visible OSC_ACCESS_TOKEN stays unchanged and
#     OSC_REFRESH_TOKEN is the original
#   - every failure (401, 5xx, empty/unparsable token, no HTTP code, jq exit
#     127) keeps the original token for config-to-env and prints a [CONFIG]
#     warning; nothing is silent

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # name actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

refresh=$(awk '/^# BEGIN runner-refresh/,/^# END runner-refresh/' "$ENTRYPOINT")
config=$(awk '/^# BEGIN config-load/,/^# END config-load/' "$ENTRYPOINT")
if [ -z "$refresh" ] || [ -z "$config" ]; then
  echo "FAIL: could not extract blocks from $ENTRYPOINT"
  exit 1
fi

SB=$(mktemp -d)
export SB
mkdir -p "$SB/bin"
printf '%s\n%s\n' "$refresh" "$config" > "$SB/block.sh"
REAL_JQ=$(command -v jq)
export REAL_JQ

# curl stub: n-th call reads curl<n>.out (body) and curl<n>.code (http code);
# records argv and the content/mode of any --data @file argument.
cat > "$SB/bin/curl" <<'EOF'
#!/bin/bash
n=$(cat "$SB/curlcount" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$SB/curlcount"
echo "$*" >> "$SB/curl_argv"
while [ $# -gt 0 ]; do
  if [ "$1" = "--data" ]; then
    f="${2#@}"
    cat "$f" >> "$SB/curl_body"
    stat -c %a "$f" >> "$SB/curl_mode"
  fi
  shift
done
[ -f "$SB/curl$n.exit" ] && exit "$(cat "$SB/curl$n.exit")"
[ -f "$SB/curl$n.out" ] && cat "$SB/curl$n.out"
printf '\n%s' "$(cat "$SB/curl$n.code" 2>/dev/null)"
exit 0
EOF
# npx stub: records the OSC_ACCESS_TOKEN it sees, prints an export line
cat > "$SB/bin/npx" <<'EOF'
#!/bin/bash
echo "$OSC_ACCESS_TOKEN" >> "$SB/npx_token"
echo "export FOO=bar"
exit 0
EOF
cat > "$SB/bin/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$SB/bin/sleep" <<'EOF'
#!/bin/bash
echo "$@" >> "$SB/sleeps"
exit 0
EOF
cat > "$SB/bin/node" <<'EOF'
#!/bin/bash
exit 0
EOF
# jq variants: real jq, or a stub that exits 127 (command not found) so a dev
# machine that happens to have jq cannot mask a missing-jq image.
cat > "$SB/bin/jq-real" <<'EOF'
#!/bin/bash
exec "$REAL_JQ" "$@"
EOF
cat > "$SB/bin/jq-127" <<'EOF'
#!/bin/bash
exit 127
EOF
chmod +x "$SB/bin/"*

cat > "$SB/harness.sh" <<'EOF'
#!/bin/bash
set -e
cp "$SB/bin/$JQ_VARIANT" "$SB/bin/jq"
export PATH="$SB/bin:/usr/bin:/bin"
OSAAS_CLI_VERSION=1.2.3
LOADING_PID=0
exec() { echo "EXEC_FAILED_STATE: $*"; exit 42; }
OSC_ENV=dev
source "$SB/block.sh"
echo "APP_OSC_ACCESS_TOKEN=${OSC_ACCESS_TOKEN}"
echo "APP_OSC_REFRESH_TOKEN=${OSC_REFRESH_TOKEN-unset}"
echo "APP_FOO=${FOO:-unset}"
EOF

reset() { rm -f "$SB"/curl* "$SB"/npx_token "$SB"/sleeps "$SB/bin/jq"; }
run() { # JQ_VARIANT defaults to jq-real
  OUT=$(env -i SB="$SB" REAL_JQ="$REAL_JQ" JQ_VARIANT="${JQ_VARIANT:-jq-real}" \
    CONFIG_SVC=store OSC_ACCESS_TOKEN=orig.refresh.tok \
    bash "$SB/harness.sh" 2>&1)
}
npx_token() { head -1 "$SB/npx_token" 2>/dev/null; }
count() { printf '%s\n' "$OUT" | grep -c -- "$1"; }

# --- success: fresh token reaches config-to-env, app keeps the original ---
reset
printf '{"token":"fresh.pat.tok","expiresIn":3600}' > "$SB/curl1.out"
echo 200 > "$SB/curl1.code"
run
check "200: config-to-env uses the fresh token" "$(npx_token)" "fresh.pat.tok"
check "200: app OSC_ACCESS_TOKEN unchanged" "$(count 'APP_OSC_ACCESS_TOKEN=orig.refresh.tok')" "1"
check "200: OSC_REFRESH_TOKEN is the original" "$(count 'APP_OSC_REFRESH_TOKEN=orig.refresh.tok')" "1"
check "200: refreshed log line" "$(count 'Refreshed access token via runner refresh token')" "1"
check "200: config still loaded" "$(count 'Loaded 1 environment variable')" "1"
check "200: exported param available" "$(count 'APP_FOO=bar')" "1"
check "200: single attempt" "$(cat "$SB/curlcount")" "1"
check "200: body is {\"token\":\"<orig>\"}" "$(cat "$SB/curl_body")" '{"token":"orig.refresh.tok"}'
check "200: body file mode 600" "$(head -1 "$SB/curl_mode")" "600"
check "200: token not in curl argv" "$(grep -c 'orig.refresh.tok' "$SB/curl_argv")" "0"
check "200: no Authorization header sent" "$(grep -c 'Authorization' "$SB/curl_argv")" "0"

# --- jq exits 127 on a 200: failed exchange, original token, warning ---
reset
printf '{"token":"fresh.pat.tok","expiresIn":3600}' > "$SB/curl1.out"
echo 200 > "$SB/curl1.code"
JQ_VARIANT=jq-127 run
check "jq 127: config-to-env keeps the original token" "$(npx_token)" "orig.refresh.tok"
check "jq 127: warning printed" "$(count "WARNING: runner token exchange failed (HTTP '200')")" "1"
check "jq 127: not reported as refreshed" "$(count 'Refreshed access token')" "0"
check "jq 127: app token unchanged" "$(count 'APP_OSC_ACCESS_TOKEN=orig.refresh.tok')" "1"
check "jq 127: config still loaded" "$(count 'Loaded 1 environment variable')" "1"

# --- 200 with empty / missing / unparsable token ---
for body in '{}' '{"token":""}' 'not json'; do
  reset
  printf '%s' "$body" > "$SB/curl1.out"
  echo 200 > "$SB/curl1.code"
  run
  check "200 body '$body': original token used" "$(npx_token)" "orig.refresh.tok"
  check "200 body '$body': warning printed" "$(count 'WARNING: runner token exchange failed')" "1"
  check "200 body '$body': OSC_REFRESH_TOKEN set" "$(count 'APP_OSC_REFRESH_TOKEN=orig.refresh.tok')" "1"
done

# --- 401 expired / revoked / invalid: stop at once, no OSC_REFRESH_TOKEN ---
for code in refresh_token_expired refresh_token_revoked; do
  reset
  printf '{"code":"%s"}' "$code" > "$SB/curl1.out"
  echo 401 > "$SB/curl1.code"
  run
  check "401 $code: original token used" "$(npx_token)" "orig.refresh.tok"
  check "401 $code: warning names the code" "$(count "WARNING: runner refresh token is $code")" "1"
  check "401 $code: no retry" "$(cat "$SB/curlcount")" "1"
  check "401 $code: OSC_REFRESH_TOKEN not set" "$(count 'APP_OSC_REFRESH_TOKEN=unset')" "1"
done
reset
printf '{"code":"refresh_token_invalid"}' > "$SB/curl1.out"
echo 401 > "$SB/curl1.code"
run
check "401 invalid: original token used" "$(npx_token)" "orig.refresh.tok"
check "401 invalid: warning printed" "$(count 'is not a runner refresh token, exchange skipped')" "1"
check "401 invalid: OSC_REFRESH_TOKEN not set" "$(count 'APP_OSC_REFRESH_TOKEN=unset')" "1"

# --- 5xx x3: retried, original token ---
reset
for i in 1 2 3; do echo 500 > "$SB/curl$i.code"; done
run
check "500x3: three attempts" "$(cat "$SB/curlcount")" "3"
check "500x3: original token used" "$(npx_token)" "orig.refresh.tok"
check "500x3: warning printed" "$(count "WARNING: runner token exchange failed (HTTP '500')")" "1"

# --- curl timeout / no HTTP code ---
reset
for i in 1 2 3; do echo 28 > "$SB/curl$i.exit"; done
run
check "timeout: three attempts" "$(cat "$SB/curlcount")" "3"
check "timeout: original token used" "$(npx_token)" "orig.refresh.tok"
check "timeout: warning printed" "$(count "WARNING: runner token exchange failed (HTTP '')")" "1"
check "timeout: config still loaded" "$(count 'Loaded 1 environment variable')" "1"

# --- transient then success ---
reset
echo 503 > "$SB/curl1.code"
printf '{"token":"fresh2"}' > "$SB/curl2.out"
echo 200 > "$SB/curl2.code"
run
check "503 then 200: fresh token used" "$(npx_token)" "fresh2"

# --- gate: no OSC_ENV or no token -> block skipped ---
reset
OUT=$(env -i SB="$SB" REAL_JQ="$REAL_JQ" JQ_VARIANT=jq-real CONFIG_SVC=store \
  bash -c 'OSC_ACCESS_TOKEN=""; source <(awk "/^# BEGIN runner-refresh/,/^# END runner-refresh/" scripts/docker-entrypoint.sh); echo "CURL_CALLS=$(cat $SB/curlcount 2>/dev/null || echo 0)"' 2>&1)
check "no token: exchange skipped" "$(count 'CURL_CALLS=0')" "1"

rm -rf "$SB"
echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]

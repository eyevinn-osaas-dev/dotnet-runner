#!/usr/bin/env bash
# tests/test-entrypoint-build-failure.sh
#
# Behavioural regression test: a failing build must reach the failed-mode
# branch (`exec node /runner/loading-server.js error-page.html failed`) instead
# of aborting the entrypoint under `set -e`.
#
# The entrypoint is run from a temp copy with its absolute paths redirected
# into a sandbox and `git`, `node`, `dotnet` replaced by stubs on PATH.
# Run from the repository root: bash tests/test-entrypoint-build-failure.sh

ENTRYPOINT="$(pwd)/scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_case <publish-exit-code> [extra env assignments...]
# Sets: RC (entrypoint exit code), NODE_LOG (stub invocation log), OUT_LOG
run_case() {
  local publish_exit="$1"; shift
  local T; T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/runner" "$T/pub"
  sed -e "s#/usercontent/app#$T/work#g" \
      -e "s#/app/published#$T/pub#g" \
      -e "s#/runner/#$T/runner/#g" "$ENTRYPOINT" > "$T/entrypoint.sh"

  # git stub: `clone ... <dest>` creates dest containing a .csproj
  cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
if [[ " $* " == *" clone "* ]]; then mkdir -p "$last"; touch "$last/app.csproj"; fi
exit 0
STUB
  # node stub: log every invocation
  cat > "$T/bin/node" <<STUB
#!/usr/bin/env bash
echo "node \$*" >> "$T/node.log"
exit 0
STUB
  # dotnet stub: publish exits with the requested code; running a dll succeeds
  cat > "$T/bin/dotnet" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "publish" ]]; then
  [[ $publish_exit -eq 0 ]] && touch "$T/pub/app.dll"
  exit $publish_exit
fi
echo "dotnet \$*" >> "$T/node.log"
exit 0
STUB
  chmod +x "$T/bin/"*

  env -i PATH="$T/bin:/usr/bin:/bin" SOURCE_URL="https://example.com/o/r.git" "$@" \
    bash "$T/entrypoint.sh" > "$T/out.log" 2>&1
  RC=$?
  NODE_LOG=$(cat "$T/node.log" 2>/dev/null)
  OUT_LOG=$(cat "$T/out.log")
  rm -rf "$T"
}

# Test 1: failing dotnet publish (auto-detected .csproj) reaches failed mode
run_case 1
if [[ $RC -eq 0 && "$NODE_LOG" == *"error-page.html failed"* && "$OUT_LOG" == *"Build failed with exit code 1"* ]]; then
  pass "failing dotnet publish reaches the failed-mode branch (rc=$RC)"
else
  fail "failing dotnet publish did not reach failed mode (rc=$RC, node log: $NODE_LOG)"
fi

# Test 2: failing OSC_BUILD_CMD reaches failed mode with its exit code
run_case 0 OSC_BUILD_CMD="sh -c 'exit 7'"
if [[ $RC -eq 0 && "$NODE_LOG" == *"error-page.html failed"* && "$OUT_LOG" == *"Build failed with exit code 7"* ]]; then
  pass "failing OSC_BUILD_CMD reaches the failed-mode branch with its exit code"
else
  fail "failing OSC_BUILD_CMD did not reach failed mode (rc=$RC, node log: $NODE_LOG)"
fi

# Test 3: successful build is unchanged (no failed mode, app started)
run_case 0
if [[ "$NODE_LOG" != *"error-page.html failed"* && "$NODE_LOG" == *"dotnet "*"app.dll"* ]]; then
  pass "successful build skips failed mode and starts the app"
else
  fail "successful build behaved differently (rc=$RC, node log: $NODE_LOG)"
fi

echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]

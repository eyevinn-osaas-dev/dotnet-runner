#!/usr/bin/env bash
# tests/test-entrypoint-credential-header-auth.sh
#
# Shell regression tests for issue #15: move git clone credentials from the
# clone URL into a scoped http.<url>/.extraheader config override.
#
# Background:
#   Even with the origin/main credential-scrub fix (remote set-url after
#   clone), the clone command itself still received a credentialed URL as an
#   argument — both via the GIT_TOKEN-injected SOURCE_URL and via the
#   pre-embedded user:pass@host Gitea SOURCE_URL. git's own
#   "fatal: ... for '<url>'" stderr on a failed clone leaks that credential
#   to Loki via promtail.
#
# Fix (this PR):
#   Build GIT_AUTH_ARGS=(-c "http.<proto>://<host>/.extraheader=...") before
#   the clone call, pass it as the first argument(s) to `git`, and clone the
#   credential-free "${PROTOCOL}://${GIT_HOST_PUBLIC}${GIT_PATH}" URL.
#   Wrap the clone call in git_scrub_stderr as defense in depth.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: clone call sites use GIT_AUTH_ARGS
# ---------------------------------------------------------------------------
if grep -qF 'git "${GIT_AUTH_ARGS[@]}" clone --branch' "$ENTRYPOINT" && \
   grep -qF 'git "${GIT_AUTH_ARGS[@]}" clone --depth 1 "${PROTOCOL}' "$ENTRYPOINT"; then
  pass "both clone call sites (branch and no-branch) use GIT_AUTH_ARGS"
else
  fail "one or both clone call sites do not use GIT_AUTH_ARGS"
fi

# ---------------------------------------------------------------------------
# Test 2: clone URL argument never embeds GIT_TOKEN or unscrubbed GIT_HOST
# ---------------------------------------------------------------------------
if grep -qE 'clone.*\$\{GIT_TOKEN\}' "$ENTRYPOINT"; then
  fail "clone call embeds GIT_TOKEN directly in the URL"
else
  pass "clone call never embeds GIT_TOKEN in the URL"
fi

if grep -qE 'clone.*"\$\{PROTOCOL\}://\$\{GIT_HOST\}\$\{GIT_PATH\}"' "$ENTRYPOINT"; then
  fail "clone call uses unscrubbed GIT_HOST (may contain embedded creds)"
else
  pass "clone call never uses unscrubbed GIT_HOST"
fi

# ---------------------------------------------------------------------------
# Test 3: GIT_AUTH_ARGS is scoped to a specific http.<url>/.extraheader,
# not a bare http.extraheader=
# ---------------------------------------------------------------------------
if grep -qF 'http.extraheader=' "$ENTRYPOINT"; then
  fail "found a bare http.extraheader= (unscoped — would apply to all git operations)"
else
  pass "no bare http.extraheader= found"
fi

if grep -qF 'http.${PROTOCOL}://${GIT_HOST_PUBLIC}/.extraheader=' "$ENTRYPOINT"; then
  pass "GIT_AUTH_ARGS is scoped to http.<protocol>://<host>/.extraheader="
else
  fail "GIT_AUTH_ARGS scoping to http.<protocol>://<host>/.extraheader= not found"
fi

# ---------------------------------------------------------------------------
# Test 4: git_scrub_stderr wraps the clone call
# ---------------------------------------------------------------------------
if grep -qF 'git_scrub_stderr git "${GIT_AUTH_ARGS[@]}" clone' "$ENTRYPOINT"; then
  pass "git_scrub_stderr wraps the clone call"
else
  fail "git_scrub_stderr does not wrap the clone call"
fi

# ---------------------------------------------------------------------------
# Test 5: bash -n passes (syntax check)
# ---------------------------------------------------------------------------
if bash -n "$ENTRYPOINT" 2>/dev/null; then
  pass "bash -n scripts/docker-entrypoint.sh passes"
else
  fail "bash -n scripts/docker-entrypoint.sh failed"
fi

# ---------------------------------------------------------------------------
# Test 6: sandboxed check — GIT_TOKEN path never appears raw in GIT_AUTH_ARGS
# ---------------------------------------------------------------------------
sandbox_token=$(bash -c '
  SOURCE_URL="https://github.com/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  GIT_PATH="/${SOURCE_URL#*://*/}"
  [[ "/${SOURCE_URL}" == "${GIT_PATH}" ]] && GIT_PATH="/"
  PROTOCOL="${SOURCE_URL%%://*}"

  GIT_TOKEN="ghp_fakevalue123456789012345678"
  GIT_AUTH_ARGS=()
  if [[ -n "$GIT_TOKEN" ]]; then
    AUTH_B64=$(printf "%s" "x-access-token:${GIT_TOKEN}" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.${PROTOCOL}://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi
  echo "${GIT_AUTH_ARGS[@]}"
')

if echo "$sandbox_token" | grep -q 'ghp_fakevalue123456789012345678'; then
  fail "raw GIT_TOKEN value appears in built GIT_AUTH_ARGS: $sandbox_token"
else
  pass "raw GIT_TOKEN value never appears in built GIT_AUTH_ARGS (only base64)"
fi

if echo "$sandbox_token" | grep -qE 'http\.https://github\.com/\.extraheader=AUTHORIZATION: basic [A-Za-z0-9+/=]+$'; then
  pass "GIT_AUTH_ARGS contains the expected scoped extraheader with base64 payload"
else
  fail "GIT_AUTH_ARGS does not match expected shape: $sandbox_token"
fi

# ---------------------------------------------------------------------------
# Test 7: sandboxed check — Gitea path preserves a literal '@' in the
# password (last-'@' split) and only its base64 form appears in GIT_AUTH_ARGS
# ---------------------------------------------------------------------------
sandbox_gitea=$(bash -c '
  SOURCE_URL="https://user:p@ssw0rd@example.com/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  GIT_PATH="/${SOURCE_URL#*://*/}"
  [[ "/${SOURCE_URL}" == "${GIT_PATH}" ]] && GIT_PATH="/"
  PROTOCOL="${SOURCE_URL%%://*}"

  GIT_TOKEN=""
  GIT_AUTH_ARGS=()
  if [[ -n "$GIT_TOKEN" ]]; then
    AUTH_B64=$(printf "%s" "x-access-token:${GIT_TOKEN}" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.${PROTOCOL}://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
    CREDS="${GIT_HOST%@*}"
    echo "CREDS=$CREDS"
    AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.${PROTOCOL}://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi
  echo "${GIT_AUTH_ARGS[@]}"
')

if echo "$sandbox_gitea" | grep -q '^CREDS=user:p@ssw0rd$'; then
  pass "Gitea CREDS preserves the literal '@' in the password (last-@ split)"
else
  fail "Gitea CREDS did not preserve the password's literal '@': $sandbox_gitea"
fi

auth_args_line=$(echo "$sandbox_gitea" | grep -v '^CREDS=')
if echo "$auth_args_line" | grep -q 'p@ssw0rd'; then
  fail "raw Gitea password appears unencoded in GIT_AUTH_ARGS output: $auth_args_line"
else
  pass "raw Gitea password never appears unencoded in GIT_AUTH_ARGS (only base64)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0

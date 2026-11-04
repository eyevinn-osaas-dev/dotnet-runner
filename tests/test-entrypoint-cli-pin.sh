#!/usr/bin/env bash
# Checks that the entrypoint runs @osaas/cli at the pinned OSAAS_CLI_VERSION
# and fails fast when it is unset.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$3', got '$2')"; fail=1; fi; }

# Extract the config-to-env command line from the entrypoint
line=$(grep 'npx -y "@osaas/cli@' "$root/scripts/docker-entrypoint.sh" | head -1 | sed -e 's/^ *if //' -e 's/; then *$//')
printf '#!/bin/bash\necho "NPX_ARGS: $*"\n' > "$tmp/npx"; chmod +x "$tmp/npx"
# timeout is a coreutils binary; stub it to just exec the command
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$tmp/timeout"; chmod +x "$tmp/timeout"
config_err_file="$tmp/err"
printf '%s\n' "set -e" "CONFIG_SVC=store" "config_err_file=$config_err_file" "$line" 'echo "$config_env_output"' > "$tmp/block.sh"

# Passing path: pinned spec is used
out=$(env -i PATH="$tmp:$PATH" OSAAS_CLI_VERSION=4.35.0 bash "$tmp/block.sh" 2>&1)
check "npx uses pinned spec" "$(echo "$out" | grep -c 'NPX_ARGS: -y @osaas/cli@4.35.0 web config-to-env')" "1"

# Failing path: unset version aborts and never calls npx
out=$(env -i PATH="$tmp:$PATH" bash "$tmp/block.sh" 2>&1); rc=$?
check "unset version fails" "$([ $rc -ne 0 ] && echo yes)" "yes"
check "unset version never runs npx" "$(echo "$out" | grep -c NPX_ARGS)" "0"

# No floating tag, and the version is pinned exactly once per Dockerfile
check "no @latest for @osaas/cli" "$(grep -rn '@osaas/cli@latest' "$root/scripts" "$root"/Dockerfile* | wc -l | tr -d ' ')" "0"
for d in "$root"/Dockerfile*; do
  check "version pinned once in $(basename "$d")" "$(grep -c '^ENV OSAAS_CLI_VERSION=' "$d")" "1"
done
exit $fail

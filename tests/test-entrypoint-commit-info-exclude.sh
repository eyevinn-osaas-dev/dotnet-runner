#!/usr/bin/env bash
# Hermetic test: .commit-info.json and the injected Directory.Build.props must not
# show in `git status` in the user's checkout. Needs git and jq.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ROOT/scripts/docker-entrypoint.sh"
FAILS=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FUNCS="$TMP/funcs.sh"
{
  sed -n '/^exclude_from_git_status() {/,/^}/p' "$ENTRY"
  sed -n '/^write_commit_info() {/,/^}/p' "$ENTRY"
  echo 'inject_build_props() {'
  sed -n '/^if \[\[ ! -f "\$BUILD_DIR\/Directory.Build.props" \]\]/,/^fi$/p' "$ENTRY"
  echo '}'
} > "$FUNCS"
check "functions extracted" 'grep -q "^write_commit_info()" "$FUNCS" && grep -q "^exclude_from_git_status()" "$FUNCS" && grep -q "ImplicitUsings" "$FUNCS"'

CALLER="$TMP/caller"; mkdir -p "$CALLER"

new_repo() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q
  echo hi > "$r/app.txt"
  git -C "$r" add app.txt
  git -C "$r" -c user.email=t@example.com -c user.name=T commit -qm "init"
}

# Run in a subshell whose cwd is NOT the repo (the entrypoint runs from /runner).
run() { ( cd "$CALLER" && source "$FUNCS" && "$@" >/dev/null 2>&1 ); }

# --- main case: WORK_DIR == BUILD_DIR
REPO="$TMP/repo"; new_repo "$REPO"
mkdir -p "$REPO/.git/info"
echo "user-rule.log" >> "$REPO/.git/info/exclude"
BEFORE="$(git -C "$REPO" rev-list --count HEAD)"
export WORK_DIR="$REPO" BUILD_DIR="$REPO"
run write_commit_info "$REPO"
run inject_build_props
check ".commit-info.json contains sha" 'grep -q "\"sha\"" "$REPO/.commit-info.json"'
check "Directory.Build.props injected" 'grep -q ImplicitUsings "$REPO/Directory.Build.props"'
check "git status --porcelain empty (AC1/AC2)" '[ -z "$(git -C "$REPO" status --porcelain)" ]'
run write_commit_info "$REPO"
run inject_build_props
check "exclude idempotent (.commit-info.json)" '[ "$(grep -cxF .commit-info.json "$REPO/.git/info/exclude")" = 1 ]'
check "exclude idempotent (Directory.Build.props)" '[ "$(grep -cxF Directory.Build.props "$REPO/.git/info/exclude")" = 1 ]'
check "user exclude rule survives" 'grep -qxF user-rule.log "$REPO/.git/info/exclude"'
check "no commit created" '[ "$(git -C "$REPO" rev-list --count HEAD)" = "$BEFORE" ]'
check "no .gitignore created" '[ ! -e "$REPO/.gitignore" ]'
check "no staged/unstaged diff" 'git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet'
check "caller cwd has no .git" '[ ! -e "$CALLER/.git" ]'

# --- SUB_PATH variant: BUILD_DIR is a subdirectory
SREPO="$TMP/subrepo"; new_repo "$SREPO"; mkdir -p "$SREPO/sub"
echo x > "$SREPO/sub/p.txt"; git -C "$SREPO" add sub/p.txt
git -C "$SREPO" -c user.email=t@example.com -c user.name=T commit -qm "sub"
export WORK_DIR="$SREPO" BUILD_DIR="$SREPO/sub"
run write_commit_info "$SREPO"
run inject_build_props
check "SUB_PATH: props injected in sub dir" 'grep -q ImplicitUsings "$SREPO/sub/Directory.Build.props"'
check "SUB_PATH: git status --porcelain empty" '[ -z "$(git -C "$SREPO" status --porcelain)" ]'

# --- repo with its own tracked Directory.Build.props: left alone
UREPO="$TMP/userprops"; new_repo "$UREPO"
echo '<Project/>' > "$UREPO/Directory.Build.props"
git -C "$UREPO" add Directory.Build.props
git -C "$UREPO" -c user.email=t@example.com -c user.name=T commit -qm "props"
export WORK_DIR="$UREPO" BUILD_DIR="$UREPO"
run write_commit_info "$UREPO"
run inject_build_props
check "user props unchanged" '[ "$(cat "$UREPO/Directory.Build.props")" = "<Project/>" ]'
check "user props not excluded" '! grep -qxF Directory.Build.props "$UREPO/.git/info/exclude"'
check "user props: git status empty" '[ -z "$(git -C "$UREPO" status --porcelain)" ]'

# --- set -e safety on a non-repo
OUT="$( ( set -e; cd "$CALLER"; source "$FUNCS"; exclude_from_git_status "$TMP/not-a-repo" x; echo reached ) 2>/dev/null )"
check "set -e safe on non-repo" '[ "$OUT" = reached ]'

if [ "$FAILS" = 0 ]; then echo "ALL PASSED"; else echo "$FAILS failed"; exit 1; fi

#!/bin/bash
set -e

PORT=${PORT:-8080}
WORK_DIR="/usercontent/app"

# Start loading server to show build status
node /runner/loading-server.js &
LOADING_PID=$!

cleanup() {
  kill $LOADING_PID 2>/dev/null || true
}
trap cleanup EXIT

# ---- Clone phase ----
SOURCE_URL="${SOURCE_URL:-$GITHUB_URL}"
if [[ -z "$SOURCE_URL" ]]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

# Extract branch from URL fragment
BRANCH=""
if [[ "$SOURCE_URL" == *"#"* ]]; then
  BRANCH="${SOURCE_URL#*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

# Inject token if provided
GIT_TOKEN="${GIT_TOKEN:-$GITHUB_TOKEN}"
if [[ -n "$GIT_TOKEN" ]]; then
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_PATH="/${SOURCE_URL#*://*/}"
  [[ "/${SOURCE_URL}" == "${GIT_PATH}" ]] && GIT_PATH="/"
  if [[ "$SOURCE_URL" == *"#"* ]]; then
    GIT_PATH="${GIT_PATH%%#*}"
  fi
  PROTOCOL="${SOURCE_URL%%://*}"
  SOURCE_URL="${PROTOCOL}://${GIT_TOKEN}@${GIT_HOST}${GIT_PATH}"
fi

rm -rf "$WORK_DIR"
if [[ -n "$BRANCH" ]]; then
  git clone --branch "$BRANCH" --depth 1 "$SOURCE_URL" "$WORK_DIR"
else
  git clone --depth 1 "$SOURCE_URL" "$WORK_DIR"
fi

# ---- Sub-path support ----
BUILD_DIR="$WORK_DIR"
if [[ -n "$SUB_PATH" ]]; then
  BUILD_DIR="$WORK_DIR/$SUB_PATH"
fi

# ---- Config service phase ----
if [[ -n "$OSC_ACCESS_TOKEN" && -n "$CONFIG_SVC" ]]; then
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env "$CONFIG_SVC" 2>&1)
  config_exit=$?
  if [ $config_exit -eq 0 ]; then
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=")
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_env_output" >&2
  fi
fi

# ---- Build phase ----
cd "$BUILD_DIR"
mkdir -p /app/published

BUILD_EXIT=0
if [[ -n "$OSC_BUILD_CMD" ]]; then
  eval "$OSC_BUILD_CMD"
  BUILD_EXIT=$?
else
  # Auto-detect project: look for *.sln first, then *.csproj
  SLN_FILE=$(find . -maxdepth 2 -name "*.sln" | head -1)
  CSPROJ_FILE=$(find . -maxdepth 3 -name "*.csproj" | head -1)

  if [[ -n "$SLN_FILE" ]]; then
    echo "[BUILD] Found solution file: $SLN_FILE"
    dotnet publish "$SLN_FILE" -c Release -o /app/published
    BUILD_EXIT=$?
  elif [[ -n "$CSPROJ_FILE" ]]; then
    echo "[BUILD] Found project file: $CSPROJ_FILE"
    dotnet publish "$CSPROJ_FILE" -c Release -o /app/published
    BUILD_EXIT=$?
  else
    echo "[BUILD] No .sln or .csproj found, attempting dotnet publish ." >&2
    dotnet publish . -c Release -o /app/published
    BUILD_EXIT=$?
  fi
fi

if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "Build failed with exit code $BUILD_EXIT" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

# ---- Run phase ----
kill $LOADING_PID 2>/dev/null || true
wait $LOADING_PID 2>/dev/null || true
trap - EXIT

if [[ -n "$OSC_ENTRY" ]]; then
  exec dotnet /app/published/${OSC_ENTRY}
else
  # Auto-detect entry DLL: find *.dll in /app/published that matches project name
  ENTRY_DLL=$(find /app/published -maxdepth 1 -name "*.dll" ! -name "*.deps.dll" ! -name "*.pdb" | grep -v runtimes | head -1)
  if [[ -z "$ENTRY_DLL" ]]; then
    echo "ERROR: No entry DLL found in /app/published" >&2
    exec node /runner/loading-server.js error-page.html failed
  fi
  echo "[RUN] Starting: dotnet $ENTRY_DLL"
  exec dotnet "$ENTRY_DLL"
fi

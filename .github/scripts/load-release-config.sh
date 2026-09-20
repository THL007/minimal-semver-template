#!/usr/bin/env bash
# Load .github/release-config.yml into RELEASE_* env vars.
# Existing RELEASE_* / OPENROUTER_MODEL values win over the file.
# Prints KEY=value lines suitable for $GITHUB_OUTPUT / $GITHUB_ENV.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${RELEASE_CONFIG_PATH:-$ROOT/.github/release-config.yml}"

# Defaults
declare -A DEFAULTS=(
  [version_bump]=true
  [changelog]=true
  [ai_changelog]=false
  [ai_changelog_fallback]=true
  [commit_release]=true
  [tag_release]=true
  [sequential_bumps]=true
  [intermediate_changelog]=true
  [openrouter_model]=openai/gpt-4o-mini
)

normalize_bool() {
  local v
  v="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$v" in
    1|true|yes|on) echo true ;;
    0|false|no|off|"") echo false ;;
    *) echo "$v" ;;
  esac
}

# Parse flat key: value file (comments + blanks ignored).
declare -A FILE_VALS=()
if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^([a-z0-9_]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val%\"}"
      val="${val#\"}"
      val="${val%\'}"
      val="${val#\'}"
      FILE_VALS["$key"]="$val"
    fi
  done < "$CONFIG"
  echo "Loaded release config: $CONFIG" >&2
else
  echo "No release config at $CONFIG; using defaults." >&2
fi

resolve() {
  local key="$1"
  local env_key="RELEASE_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
  local env_val="${!env_key-}"
  local file_val="${FILE_VALS[$key]-}"
  local default_val="${DEFAULTS[$key]}"

  if [ -n "${env_val}" ]; then
    echo "$env_val"
  elif [ -n "${file_val}" ]; then
    echo "$file_val"
  else
    echo "$default_val"
  fi
}

VERSION_BUMP="$(normalize_bool "$(resolve version_bump)")"
CHANGELOG="$(normalize_bool "$(resolve changelog)")"
AI_CHANGELOG="$(normalize_bool "$(resolve ai_changelog)")"
AI_CHANGELOG_FALLBACK="$(normalize_bool "$(resolve ai_changelog_fallback)")"
COMMIT_RELEASE="$(normalize_bool "$(resolve commit_release)")"
TAG_RELEASE="$(normalize_bool "$(resolve tag_release)")"
SEQUENTIAL_BUMPS="$(normalize_bool "$(resolve sequential_bumps)")"
INTERMEDIATE_CHANGELOG="$(normalize_bool "$(resolve intermediate_changelog)")"
OPENROUTER_MODEL_VAL="$(resolve openrouter_model)"

# Prefer explicit OPENROUTER_MODEL if already set.
if [ -n "${OPENROUTER_MODEL:-}" ]; then
  OPENROUTER_MODEL_VAL="$OPENROUTER_MODEL"
fi

if [ "$TAG_RELEASE" = true ] && [ "$COMMIT_RELEASE" = false ]; then
  echo "tag_release requires commit_release; forcing tag_release=false" >&2
  TAG_RELEASE=false
fi

if [ "$AI_CHANGELOG" = true ] && [ "$CHANGELOG" = false ]; then
  echo "ai_changelog requires changelog; forcing ai_changelog=false" >&2
  AI_CHANGELOG=false
fi

if [ "$SEQUENTIAL_BUMPS" = false ] && [ "$INTERMEDIATE_CHANGELOG" = true ]; then
  echo "intermediate_changelog requires sequential_bumps; forcing intermediate_changelog=false" >&2
  INTERMEDIATE_CHANGELOG=false
fi

export RELEASE_VERSION_BUMP="$VERSION_BUMP"
export RELEASE_CHANGELOG="$CHANGELOG"
export RELEASE_AI_CHANGELOG="$AI_CHANGELOG"
export RELEASE_AI_CHANGELOG_FALLBACK="$AI_CHANGELOG_FALLBACK"
export RELEASE_COMMIT_RELEASE="$COMMIT_RELEASE"
export RELEASE_TAG_RELEASE="$TAG_RELEASE"
export RELEASE_SEQUENTIAL_BUMPS="$SEQUENTIAL_BUMPS"
export RELEASE_INTERMEDIATE_CHANGELOG="$INTERMEDIATE_CHANGELOG"
export RELEASE_OPENROUTER_MODEL="$OPENROUTER_MODEL_VAL"
export OPENROUTER_MODEL="$OPENROUTER_MODEL_VAL"

emit() {
  local key="$1"
  local val="$2"
  echo "${key}=${val}"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_ENV"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_OUTPUT"
  fi
}

emit RELEASE_VERSION_BUMP "$VERSION_BUMP"
emit RELEASE_CHANGELOG "$CHANGELOG"
emit RELEASE_AI_CHANGELOG "$AI_CHANGELOG"
emit RELEASE_AI_CHANGELOG_FALLBACK "$AI_CHANGELOG_FALLBACK"
emit RELEASE_COMMIT_RELEASE "$COMMIT_RELEASE"
emit RELEASE_TAG_RELEASE "$TAG_RELEASE"
emit RELEASE_SEQUENTIAL_BUMPS "$SEQUENTIAL_BUMPS"
emit RELEASE_INTERMEDIATE_CHANGELOG "$INTERMEDIATE_CHANGELOG"
emit RELEASE_OPENROUTER_MODEL "$OPENROUTER_MODEL_VAL"
emit OPENROUTER_MODEL "$OPENROUTER_MODEL_VAL"

echo "Switches: bump=${VERSION_BUMP} changelog=${CHANGELOG} ai=${AI_CHANGELOG} commit=${COMMIT_RELEASE} tag=${TAG_RELEASE} sequential=${SEQUENTIAL_BUMPS} intermediate=${INTERMEDIATE_CHANGELOG}" >&2

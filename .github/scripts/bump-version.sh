#!/usr/bin/env bash
# Apply semver bumps from commit history and optionally write CHANGELOG.
# Feature switches: see .github/release-config.yml / load-release-config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD_SHA="${HEAD_SHA:-HEAD}"

# Load switches if not already present (local runs).
if [ -z "${RELEASE_VERSION_BUMP:-}" ]; then
  # shellcheck disable=SC1091
  source <(bash "${SCRIPT_DIR}/load-release-config.sh" | sed '/^Switches:/d')
fi

RELEASE_VERSION_BUMP="${RELEASE_VERSION_BUMP:-true}"
RELEASE_CHANGELOG="${RELEASE_CHANGELOG:-true}"
RELEASE_CHANGELOG_INTERNAL="${RELEASE_CHANGELOG_INTERNAL:-true}"
RELEASE_CHANGELOG_EXTERNAL="${RELEASE_CHANGELOG_EXTERNAL:-true}"
RELEASE_AI_CHANGELOG="${RELEASE_AI_CHANGELOG:-false}"
RELEASE_AI_CHANGELOG_FALLBACK="${RELEASE_AI_CHANGELOG_FALLBACK:-true}"
RELEASE_SEQUENTIAL_BUMPS="${RELEASE_SEQUENTIAL_BUMPS:-true}"
RELEASE_INTERMEDIATE_CHANGELOG="${RELEASE_INTERMEDIATE_CHANGELOG:-true}"

# Master changelog switch gates both audiences.
if [ "$RELEASE_CHANGELOG" != true ]; then
  RELEASE_CHANGELOG_INTERNAL=false
  RELEASE_CHANGELOG_EXTERNAL=false
fi

if [ "$RELEASE_VERSION_BUMP" != true ] \
  && [ "$RELEASE_CHANGELOG_INTERNAL" != true ] \
  && [ "$RELEASE_CHANGELOG_EXTERNAL" != true ]; then
  echo "version_bump and both changelogs are disabled; nothing to do."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "bumped=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [ -n "${ANALYZE_RANGE:-}" ]; then
  echo "Analyzing commits: ${ANALYZE_RANGE}"
else
  BASE_SHA="${BASE_SHA:-}"
  BASE_REF="${BASE_REF:-main}"

  if [ -n "$BASE_SHA" ]; then
    COMMIT_RANGE="${BASE_SHA}..${HEAD_SHA}"
  else
    COMMIT_RANGE="origin/${BASE_REF}..${HEAD_SHA}"
  fi

  echo "Commit range: ${COMMIT_RANGE}"

  LAST_RELEASE_SHA=""
  while IFS= read -r sha; do
    subject="$(git log -1 --format=%s "$sha")"
    if [[ "$subject" =~ ^chore\(release\): ]]; then
      LAST_RELEASE_SHA="$sha"
      break
    fi
  done < <(git log --format=%H "${COMMIT_RANGE}" --no-merges 2>/dev/null || true)

  if [ -n "$LAST_RELEASE_SHA" ]; then
    ANALYZE_RANGE="${LAST_RELEASE_SHA}..${HEAD_SHA}"
    echo "Last release: ${LAST_RELEASE_SHA}"
    echo "New commits only: ${ANALYZE_RANGE}"
  else
    ANALYZE_RANGE="${COMMIT_RANGE}"
    echo "All commits in range: ${ANALYZE_RANGE}"
  fi
fi

mapfile -t COMMIT_SHAS < <(
  git log --reverse --format=%H "${ANALYZE_RANGE}" --no-merges 2>/dev/null || true
)

if [ "${#COMMIT_SHAS[@]}" -eq 0 ]; then
  echo "No new commits to release; skipping bump."
  exit 0
fi

echo "Found ${#COMMIT_SHAS[@]} commit(s) to release (oldest first):"

classify_bump() {
  local subject="$1"

  if [[ "$subject" =~ ^chore\(release\): ]]; then
    echo "skip"
    return
  fi

  if [[ "$subject" =~ \(major\) ]] \
    || [[ "$subject" =~ BREAKING\ CHANGE ]] \
    || [[ "$subject" =~ ^[a-zA-Z]+\(.+\)!: ]] \
    || [[ "$subject" =~ ^[a-zA-Z]+! ]]; then
    echo "major"
    return
  fi

  if [[ "$subject" =~ \(minor\) ]]; then
    echo "minor"
    return
  fi

  if [[ "$subject" =~ \(patch\) ]]; then
    echo "patch"
    return
  fi

  if [[ "$subject" =~ ^feat(\(.+\))?: ]]; then
    echo "minor"
    return
  fi

  if [[ "$subject" =~ ^(fix|perf|refactor)(\(.+\))?: ]]; then
    echo "patch"
    return
  fi

  echo "patch"
}

apply_bump() {
  local bump="$1"
  case "$bump" in
    major)
      MAJOR=$((MAJOR + 1))
      MINOR=0
      PATCH=0
      ;;
    minor)
      MINOR=$((MINOR + 1))
      PATCH=0
      ;;
    patch)
      PATCH=$((PATCH + 1))
      ;;
    *)
      return
      ;;
  esac
}

rank_bump() {
  case "$1" in
    major) echo 3 ;;
    minor) echo 2 ;;
    patch) echo 1 ;;
    *) echo 0 ;;
  esac
}

strip_commit_prefix() {
  local subject="$1"
  if [[ "$subject" =~ ^[a-zA-Z]+ ]]; then
    subject="${subject#*: }"
  fi
  subject="$(sed -E 's/[[:space:]]*\((major|minor|patch)\)[[:space:]]*$//' <<<"$subject")"
  echo "$subject"
}

emoji_for_commit() {
  local subject="$1"
  local bump="$2"
  if [[ "$bump" == "major" ]]; then
    echo "💥"
  elif [[ "$subject" == feat* ]] || [[ "$bump" == "minor" ]]; then
    echo "✨"
  elif [[ "$subject" == fix* ]]; then
    echo "🐛"
  elif [[ "$subject" == perf* ]]; then
    echo "⚡"
  elif [[ "$subject" == docs* ]]; then
    echo "📝"
  elif [[ "$subject" == refactor* ]]; then
    echo "🔧"
  else
    echo "📦"
  fi
}

heading_emoji_for_bump() {
  case "$1" in
    major) echo "💥" ;;
    minor) echo "✨" ;;
    patch) echo "🐛" ;;
    *) echo "📦" ;;
  esac
}

insert_before_first_heading() {
  local target="$1"
  local entry_file="$2"
  awk -v entry_file="$entry_file" '
    BEGIN { while ((getline line < entry_file) > 0) entry = entry line "\n"; close(entry_file) }
    /^## / && !inserted { print entry; inserted=1 }
    { print }
    END { if (!inserted) print entry }
  ' "$target" > "${target}.tmp"
  mv "${target}.tmp" "$target"
}

write_fallback_internal() {
  local i subject version bump summary

  if [ "$RELEASE_INTERMEDIATE_CHANGELOG" = true ]; then
    {
      for ((i = ${#CHANGE_SUBJECTS[@]} - 1; i >= 0; i--)); do
        subject="${CHANGE_SUBJECTS[$i]}"
        version="${CHANGE_VERSIONS[$i]}"
        bump="${CHANGE_BUMPS[$i]}"
        summary="$(strip_commit_prefix "$subject")"

        echo "## [${version}] - ${TODAY}"
        echo ""
        case "$bump" in
          minor) echo "### Added" ;;
          patch)
            if [[ "$subject" == fix* ]]; then
              echo "### Fixed"
            elif [[ "$subject" == refactor* || "$subject" == perf* ]]; then
              echo "### Changed"
            else
              echo "### Other"
            fi
            ;;
          major) echo "### Changed" ;;
        esac
        echo ""
        echo "- ${summary}"
        echo ""
      done
    } > /tmp/changelog-internal-entry.md
    return
  fi

  {
    echo "## [${NEW_VERSION}] - ${TODAY}"
    echo ""
    local added=() changed=() fixed=() other=()
    for ((i = 0; i < ${#CHANGE_SUBJECTS[@]}; i++)); do
      subject="${CHANGE_SUBJECTS[$i]}"
      bump="${CHANGE_BUMPS[$i]}"
      summary="$(strip_commit_prefix "$subject")"
      case "$bump" in
        minor) added+=("- ${summary}") ;;
        major) changed+=("- ${summary}") ;;
        patch)
          if [[ "$subject" == fix* ]]; then
            fixed+=("- ${summary}")
          elif [[ "$subject" == refactor* || "$subject" == perf* ]]; then
            changed+=("- ${summary}")
          else
            other+=("- ${summary}")
          fi
          ;;
      esac
    done
    if [ "${#added[@]}" -gt 0 ]; then
      echo "### Added"; echo ""; printf '%s\n' "${added[@]}"; echo ""
    fi
    if [ "${#changed[@]}" -gt 0 ]; then
      echo "### Changed"; echo ""; printf '%s\n' "${changed[@]}"; echo ""
    fi
    if [ "${#fixed[@]}" -gt 0 ]; then
      echo "### Fixed"; echo ""; printf '%s\n' "${fixed[@]}"; echo ""
    fi
    if [ "${#other[@]}" -gt 0 ]; then
      echo "### Other"; echo ""; printf '%s\n' "${other[@]}"; echo ""
    fi
  } > /tmp/changelog-internal-entry.md
}

write_fallback_external() {
  local i subject version bump summary emoji hemoji

  if [ "$RELEASE_INTERMEDIATE_CHANGELOG" = true ]; then
    {
      for ((i = ${#CHANGE_SUBJECTS[@]} - 1; i >= 0; i--)); do
        subject="${CHANGE_SUBJECTS[$i]}"
        version="${CHANGE_VERSIONS[$i]}"
        bump="${CHANGE_BUMPS[$i]}"
        summary="$(strip_commit_prefix "$subject")"
        emoji="$(emoji_for_commit "$subject" "$bump")"
        hemoji="$(heading_emoji_for_bump "$bump")"
        echo "## ${hemoji} ${version} — ${TODAY}"
        echo ""
        echo "- ${emoji} ${summary}"
        echo ""
      done
    } > /tmp/changelog-external-entry.md
    return
  fi

  {
    hemoji="$(heading_emoji_for_bump "$HIGHEST_BUMP")"
    echo "## ${hemoji} ${NEW_VERSION} — ${TODAY}"
    echo ""
    for ((i = 0; i < ${#CHANGE_SUBJECTS[@]}; i++)); do
      subject="${CHANGE_SUBJECTS[$i]}"
      bump="${CHANGE_BUMPS[$i]}"
      summary="$(strip_commit_prefix "$subject")"
      emoji="$(emoji_for_commit "$subject" "$bump")"
      echo "- ${emoji} ${summary}"
    done
    echo ""
  } > /tmp/changelog-external-entry.md
}

maybe_ai_changelog() {
  local audience="$1"
  local out_file="$2"
  local fallback_file="$3"

  if [ "$fallback_file" != "$out_file" ]; then
    cp "$fallback_file" "$out_file"
  fi

  if [ "$RELEASE_AI_CHANGELOG" != true ]; then
    return 0
  fi

  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "ai_changelog enabled but OPENROUTER_API_KEY is unset (${audience})." >&2
    if [ "$RELEASE_AI_CHANGELOG_FALLBACK" != true ]; then
      return 1
    fi
    echo "Using heuristic ${audience} changelog fallback."
    return 0
  fi

  echo "Generating ${audience} changelog via OpenRouter (${OPENROUTER_MODEL:-openai/gpt-4o-mini})..."
  if TODAY="$TODAY" CHANGELOG_AUDIENCE="$audience" \
    bash "${SCRIPT_DIR}/ai-changelog.sh" "$DUMP_FILE" > "${out_file}.ai"; then
    mv "${out_file}.ai" "$out_file"
    echo "AI ${audience} changelog applied."
  else
    echo "AI ${audience} changelog failed." >&2
    rm -f "${out_file}.ai"
    if [ "$RELEASE_AI_CHANGELOG_FALLBACK" != true ]; then
      return 1
    fi
    echo "Using heuristic ${audience} changelog fallback."
  fi
}

CURRENT="$(tr -d '[:space:]' < VERSION)"
CURRENT="${CURRENT#v}"

echo "Current VERSION: ${CURRENT}"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

APPLIED=0
HIGHEST_BUMP="none"
CHANGE_SHAS=()
CHANGE_SUBJECTS=()
CHANGE_BODIES=()
CHANGE_STATS=()
CHANGE_VERSIONS=()
CHANGE_BUMPS=()

for sha in "${COMMIT_SHAS[@]}"; do
  subject="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%b "$sha" | sed -E '/^(Co-authored-by|Signed-off-by|Made-with):/Id')"
  stat="$(git show --stat --format='' "$sha" 2>/dev/null | tail -n 20 || true)"

  bump="$(classify_bump "$subject")"
  if [[ "$bump" == "skip" ]]; then
    echo "  skip: ${subject}"
    continue
  fi

  CHANGE_SHAS+=("$sha")
  CHANGE_SUBJECTS+=("$subject")
  CHANGE_BODIES+=("$body")
  CHANGE_STATS+=("$stat")
  CHANGE_BUMPS+=("$bump")
  APPLIED=$((APPLIED + 1))

  if [ "$(rank_bump "$bump")" -gt "$(rank_bump "$HIGHEST_BUMP")" ]; then
    HIGHEST_BUMP="$bump"
  fi
done

if [ "$APPLIED" -eq 0 ]; then
  echo "No bump required."
  exit 0
fi

if [ "$RELEASE_SEQUENTIAL_BUMPS" = true ]; then
  MAJOR="${CURRENT%%.*}"
  rest="${CURRENT#*.}"
  MINOR="${rest%%.*}"
  PATCH="${rest#*.}"
  CHANGE_VERSIONS=()
  for bump in "${CHANGE_BUMPS[@]}"; do
    apply_bump "$bump"
    CHANGE_VERSIONS+=("${MAJOR}.${MINOR}.${PATCH}")
    echo "  ${bump}: → ${MAJOR}.${MINOR}.${PATCH}"
  done
  echo "Mode: sequential bumps"
else
  apply_bump "$HIGHEST_BUMP"
  for ((i = 0; i < ${#CHANGE_BUMPS[@]}; i++)); do
    CHANGE_VERSIONS+=("${MAJOR}.${MINOR}.${PATCH}")
  done
  echo "Mode: single highest bump (${HIGHEST_BUMP}) → ${MAJOR}.${MINOR}.${PATCH}"
fi

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TODAY="$(date -u +%Y-%m-%d)"

if [ "$RELEASE_VERSION_BUMP" = true ]; then
  if [ "$NEW_VERSION" = "$CURRENT" ]; then
    echo "Computed version unchanged (${NEW_VERSION}); skipping."
    exit 0
  fi
  echo "$NEW_VERSION" > VERSION
  echo "Bumped ${CURRENT} -> ${NEW_VERSION} (${APPLIED} commit(s))"
else
  echo "version_bump disabled; leaving VERSION at ${CURRENT}"
  NEW_VERSION="$CURRENT"
fi

DUMP_FILE="/tmp/release-commits.json"
{
  echo '['
  for ((i = 0; i < ${#CHANGE_SHAS[@]}; i++)); do
    [ "$i" -gt 0 ] && echo ','
    version_for_dump="${CHANGE_VERSIONS[$i]}"
    if [ "$RELEASE_VERSION_BUMP" != true ]; then
      version_for_dump="$CURRENT"
    fi
    jq -n \
      --arg sha "${CHANGE_SHAS[$i]}" \
      --arg version "$version_for_dump" \
      --arg bump "${CHANGE_BUMPS[$i]}" \
      --arg subject "${CHANGE_SUBJECTS[$i]}" \
      --arg body "${CHANGE_BODIES[$i]}" \
      --arg stat "${CHANGE_STATS[$i]}" \
      '{sha:$sha, version:$version, bump:$bump, subject:$subject, body:$body, stat:$stat}'
  done
  echo ']'
} > "$DUMP_FILE"
echo "Commit dump written to ${DUMP_FILE}"

if [ "$RELEASE_CHANGELOG_INTERNAL" = true ] || [ "$RELEASE_CHANGELOG_EXTERNAL" = true ]; then
  if [ "$RELEASE_CHANGELOG_INTERNAL" = true ]; then
    write_fallback_internal
    maybe_ai_changelog internal /tmp/changelog-internal-entry.md /tmp/changelog-internal-entry.md \
      || exit 1
    insert_before_first_heading CHANGELOG.md /tmp/changelog-internal-entry.md

    REPO_SLUG="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    if [ "$RELEASE_VERSION_BUMP" = true ] && [ "$RELEASE_INTERMEDIATE_CHANGELOG" = true ]; then
      prev_for_link="$CURRENT"
      for ((i = 0; i < ${#CHANGE_VERSIONS[@]}; i++)); do
        version="${CHANGE_VERSIONS[$i]}"
        link_line="[${version}]: https://github.com/${REPO_SLUG}/compare/v${prev_for_link}...v${version}"
        if grep -q "^\[${version}\]:" CHANGELOG.md; then
          sed -i "s|^\[${version}\]:.*|${link_line}|" CHANGELOG.md
        else
          echo "" >> CHANGELOG.md
          echo "$link_line" >> CHANGELOG.md
        fi
        prev_for_link="$version"
      done
    elif [ "$RELEASE_VERSION_BUMP" = true ]; then
      link_line="[${NEW_VERSION}]: https://github.com/${REPO_SLUG}/compare/v${CURRENT}...v${NEW_VERSION}"
      if grep -q "^\[${NEW_VERSION}\]:" CHANGELOG.md; then
        sed -i "s|^\[${NEW_VERSION}\]:.*|${link_line}|" CHANGELOG.md
      else
        echo "" >> CHANGELOG.md
        echo "$link_line" >> CHANGELOG.md
      fi
    fi
    echo "Updated CHANGELOG.md (internal)."
  else
    echo "changelog_internal disabled; leaving CHANGELOG.md unchanged."
  fi

  if [ "$RELEASE_CHANGELOG_EXTERNAL" = true ]; then
    write_fallback_external
    maybe_ai_changelog external /tmp/changelog-external-entry.md /tmp/changelog-external-entry.md \
      || exit 1
    if [ ! -f CHANGELOG.external.md ]; then
      cat > CHANGELOG.external.md <<'EOF'
# What's new

Simple, user-friendly release notes. For technical details see [CHANGELOG.md](./CHANGELOG.md).

EOF
    fi
    insert_before_first_heading CHANGELOG.external.md /tmp/changelog-external-entry.md
    echo "Updated CHANGELOG.external.md (external)."
  else
    echo "changelog_external disabled; leaving CHANGELOG.external.md unchanged."
  fi
else
  echo "Both changelogs disabled; leaving changelog files unchanged."
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new_version=${NEW_VERSION}" >> "$GITHUB_OUTPUT"
  echo "bumped=true" >> "$GITHUB_OUTPUT"
fi

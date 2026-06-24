#!/usr/bin/env bash
set -euo pipefail

HEAD_SHA="${HEAD_SHA:-HEAD}"

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

mapfile -t COMMITS < <(
  git log --format=%s "${ANALYZE_RANGE}" --no-merges 2>/dev/null || true
)

if [ "${#COMMITS[@]}" -eq 0 ]; then
  echo "No new commits to release; skipping bump."
  exit 0
fi

echo "Found ${#COMMITS[@]} commit(s) to release:"
printf '  - %s\n' "${COMMITS[@]}"

BUMP="none"

for subject in "${COMMITS[@]}"; do
  if [[ "$subject" =~ ^chore\(release\): ]]; then
    continue
  fi

  if [[ "$subject" =~ \(major\) ]] \
    || [[ "$subject" =~ BREAKING\ CHANGE ]] \
    || [[ "$subject" =~ ^[a-zA-Z]+\(.+\)!: ]] \
    || [[ "$subject" =~ ^[a-zA-Z]+! ]]; then
    BUMP="major"
    break
  fi

  if [[ "$subject" =~ ^feat(\(.+\))?: ]] && [[ "$BUMP" != "major" ]]; then
    BUMP="minor"
  fi

  if [[ "$subject" =~ ^(fix|perf|refactor)(\(.+\))?: ]] && [[ "$BUMP" == "none" ]]; then
    BUMP="patch"
  fi
done

if [[ "$BUMP" == "none" ]]; then
  for subject in "${COMMITS[@]}"; do
    if [[ ! "$subject" =~ ^chore\(release\): ]]; then
      BUMP="patch"
      break
    fi
  done
fi

if [[ "$BUMP" == "none" ]]; then
  echo "No bump required."
  exit 0
fi

CURRENT="$(tr -d '[:space:]' < VERSION)"
CURRENT="${CURRENT#v}"

echo "Current VERSION: ${CURRENT}"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

case "$BUMP" in
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
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TODAY="$(date -u +%Y-%m-%d)"

if [ "$NEW_VERSION" = "$CURRENT" ]; then
  echo "Computed version unchanged (${NEW_VERSION}); skipping."
  exit 0
fi

echo "$NEW_VERSION" > VERSION
echo "Bumped ${CURRENT} -> ${NEW_VERSION} (${BUMP})"

SECTION="## [${NEW_VERSION}] - ${TODAY}"
ADDED=()
CHANGED=()
FIXED=()
OTHER=()

strip_commit_prefix() {
  local subject="$1"
  if [[ "$subject" =~ ^[a-zA-Z]+ ]]; then
    subject="${subject#*: }"
  fi
  echo "$subject"
}

for subject in "${COMMITS[@]}"; do
  [[ "$subject" =~ ^chore\(release\): ]] && continue

  if [[ "$subject" == feat* ]]; then
    ADDED+=("- $(strip_commit_prefix "$subject")")
  elif [[ "$subject" == fix* ]]; then
    FIXED+=("- $(strip_commit_prefix "$subject")")
  elif [[ "$subject" == refactor* || "$subject" == perf* ]]; then
    CHANGED+=("- $(strip_commit_prefix "$subject")")
  else
    OTHER+=("- $(strip_commit_prefix "$subject")")
  fi
done

{
  echo "$SECTION"
  echo ""
  if [ "${#ADDED[@]}" -gt 0 ]; then
    echo "### Added"
    echo ""
    printf '%s\n' "${ADDED[@]}"
    echo ""
  fi
  if [ "${#CHANGED[@]}" -gt 0 ]; then
    echo "### Changed"
    echo ""
    printf '%s\n' "${CHANGED[@]}"
    echo ""
  fi
  if [ "${#FIXED[@]}" -gt 0 ]; then
    echo "### Fixed"
    echo ""
    printf '%s\n' "${FIXED[@]}"
    echo ""
  fi
  if [ "${#OTHER[@]}" -gt 0 ]; then
    echo "### Other"
    echo ""
    printf '%s\n' "${OTHER[@]}"
    echo ""
  fi
} > /tmp/changelog-entry.md

awk -v entry_file="/tmp/changelog-entry.md" '
  BEGIN { while ((getline line < entry_file) > 0) entry = entry line "\n"; close(entry_file) }
  /^## \[/ && !inserted { print entry; inserted=1 }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp

mv CHANGELOG.md.tmp CHANGELOG.md

PREV_TAG="v${CURRENT}"
NEW_TAG="v${NEW_VERSION}"
REPO_SLUG="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

if grep -q "^\[${NEW_VERSION}\]:" CHANGELOG.md; then
  sed -i "s|^\[${NEW_VERSION}\]:.*|[${NEW_VERSION}]: https://github.com/${REPO_SLUG}/compare/${PREV_TAG}...${NEW_TAG}|" CHANGELOG.md
else
  echo "" >> CHANGELOG.md
  echo "[${NEW_VERSION}]: https://github.com/${REPO_SLUG}/compare/${PREV_TAG}...${NEW_TAG}" >> CHANGELOG.md
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new_version=${NEW_VERSION}" >> "$GITHUB_OUTPUT"
  echo "bumped=true" >> "$GITHUB_OUTPUT"
fi

#!/usr/bin/env bash
# Generate Keep a Changelog markdown via OpenRouter from a commit dump JSON.
# Reads JSON from $1 (or stdin). Writes markdown to stdout.
# Env:
#   OPENROUTER_API_KEY  (required)
#   OPENROUTER_MODEL    (default: openai/gpt-4o-mini)
#   TODAY               (default: UTC today)
set -euo pipefail

INPUT_FILE="${1:-}"
MODEL="${OPENROUTER_MODEL:-openai/gpt-4o-mini}"
TODAY="${TODAY:-$(date -u +%Y-%m-%d)}"
API_URL="${OPENROUTER_API_URL:-https://openrouter.ai/api/v1/chat/completions}"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "OPENROUTER_API_KEY is not set" >&2
  exit 1
fi

if [ -n "$INPUT_FILE" ]; then
  DUMP="$(cat "$INPUT_FILE")"
else
  DUMP="$(cat)"
fi

if [ -z "$DUMP" ] || [ "$DUMP" = "[]" ]; then
  echo "Empty commit dump" >&2
  exit 1
fi

SYSTEM_PROMPT="$(cat <<'EOF'
You write release notes in Keep a Changelog format.

Rules:
- Output ONLY markdown. No preamble, no code fences, no commentary.
- One section per object in the dump, newest version first.
- Heading format exactly: ## [VERSION] - DATE
- Use only these subsection headings when relevant: ### Added, ### Changed, ### Fixed, ### Removed, ### Deprecated, ### Security
- Turn raw commit subjects/bodies into clear, user-facing bullet points (1–3 bullets per version).
- Drop conventional-commit noise: type prefixes, scopes, and trailing (major)/(minor)/(patch) tags.
- Do not invent features that are not supported by the commit dump.
- Prefer concrete wording over vague phrases like "various improvements".
EOF
)"

USER_PROMPT="$(cat <<EOF
DATE for all headings: ${TODAY}

Commit dump (JSON array, already ordered oldest → newest; reverse for output):
${DUMP}
EOF
)"

REQUEST_FILE="$(mktemp)"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$REQUEST_FILE" "$RESPONSE_FILE"' EXIT

jq -n \
  --arg model "$MODEL" \
  --arg system "$SYSTEM_PROMPT" \
  --arg user "$USER_PROMPT" \
  '{
    model: $model,
    temperature: 0.2,
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $user}
    ]
  }' > "$REQUEST_FILE"

HTTP_CODE="$(
  curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
    -X POST "$API_URL" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/${GITHUB_REPOSITORY:-local/template}" \
    -H "X-OpenRouter-Title: minimal-semver-template-changelog" \
    --data-binary @"$REQUEST_FILE"
)"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "OpenRouter HTTP ${HTTP_CODE}:" >&2
  cat "$RESPONSE_FILE" >&2 || true
  exit 1
fi

CONTENT="$(jq -r '.choices[0].message.content // empty' "$RESPONSE_FILE")"
if [ -z "$CONTENT" ]; then
  echo "OpenRouter returned empty content:" >&2
  cat "$RESPONSE_FILE" >&2 || true
  exit 1
fi

# Strip accidental markdown fences.
CONTENT="$(
  printf '%s\n' "$CONTENT" | sed -E '
    1{/^```([a-zA-Z0-9_-]*)?$/d;}
    ${/^```$/d;}
  '
)"

if ! grep -qE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' <<<"$CONTENT"; then
  echo "OpenRouter output missing version headings:" >&2
  printf '%s\n' "$CONTENT" >&2
  exit 1
fi

printf '%s\n' "$CONTENT"

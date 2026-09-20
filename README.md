# Minimal Semver Template

A minimal GitHub repository template with **post-merge semver bumping** and release tagging via GitHub Actions.

## What's included

- `VERSION` — current semver (`MAJOR.MINOR.PATCH`)
- `CHANGELOG.md` — [Keep a Changelog](https://keepachangelog.com/) format
- `.github/release-config.yml` — feature switches (bump, AI changelog, tag, …)
- `.github/workflows/release.yml` — release job + manual `workflow_dispatch` toggles
- `.github/scripts/bump-version.sh` — semver bumps from commit messages
- `.github/scripts/ai-changelog.sh` — optional OpenRouter changelog rewrite
- `.github/scripts/load-release-config.sh` — loads switches into the job
- `.cursor/rules/_commit-semver.mdc` — always require `(major)` / `(minor)` / `(patch)` in commits

## Feature switches

Edit `.github/release-config.yml` (or override with `RELEASE_*` env / Actions variables):

| Switch | Default | Effect |
|--------|---------|--------|
| `version_bump` | `true` | Update `VERSION` from commits |
| `changelog` | `true` | Update `CHANGELOG.md` |
| `ai_changelog` | `false` | Rewrite changelog via OpenRouter |
| `ai_changelog_fallback` | `true` | Keep heuristic notes if AI fails |
| `commit_release` | `true` | Commit release files to `main` |
| `tag_release` | `true` | Push `vX.Y.Z` (needs `commit_release`) |
| `sequential_bumps` | `true` | One bump per commit (else highest only) |
| `intermediate_changelog` | `true` | One changelog section per bump step |
| `openrouter_model` | `openai/gpt-4o-mini` | OpenRouter model id |

Manual runs: **Actions → Release → Run workflow** exposes the same toggles for a one-off job.

## How it works

1. Work on a branch, open a PR, and **merge to `main`**.
2. The **Release** workflow runs on every push to `main` (or via `workflow_dispatch`).
3. Switches load from `release-config.yml`, then commits since the last `chore(release):` are walked **oldest → newest**.
4. With `sequential_bumps: true`, each commit applies its own bump:
   - `(major)` or `BREAKING CHANGE` / `type!:` → **major**
   - `(minor)` or `feat:` → **minor**
   - `(patch)` or `fix:` / `perf:` / `refactor:` → **patch**
   - anything else → **patch**

   Example from `1.0.0`: patch → `1.0.1`, then minor → `1.1.0`, then patch → `1.1.1`.

Prefer an explicit `(major)`, `(minor)`, or `(patch)` tag on every commit (enforced via Cursor rules).
5. Writes `VERSION` / `CHANGELOG.md` according to switches (AI dump when `ai_changelog: true` + `OPENROUTER_API_KEY`).
6. Commits `chore(release): bump version to X.Y.Z` and tags `vX.Y.Z` when those switches are on.
7. If HEAD is already `chore(release):`, the workflow skips (no loop).

## AI changelog (OpenRouter)

1. Set `ai_changelog: true` in `.github/release-config.yml`.
2. Create a key at [openrouter.ai/keys](https://openrouter.ai/keys).
3. Repo **Settings → Secrets and variables → Actions**: secret `OPENROUTER_API_KEY` (optional variable `OPENROUTER_MODEL` overrides config).

## Suggested workflow

```text
feature branch → PR → merge to main → CI releases automatically
```

Optional: use a `dev` branch for day-to-day work and merge `dev` → `main` when ready to release.

## Use this template

Click **Use this template** on GitHub, flip switches in `.github/release-config.yml`, add `OPENROUTER_API_KEY` if you want AI changelogs, then start committing. The first merge to `main` with new commits will trigger your first automated release after `0.1.0`.

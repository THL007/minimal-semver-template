# Minimal Semver Template

A minimal GitHub repository template with **post-merge semver bumping** and release tagging via GitHub Actions.

## What's included

- `VERSION` — current semver (`MAJOR.MINOR.PATCH`)
- `CHANGELOG.md` — [Keep a Changelog](https://keepachangelog.com/) format
- `.github/workflows/release.yml` — bumps version and tags `main` after merges
- `.github/scripts/bump-version.sh` — semver logic from commit messages

## How it works

1. Work on a branch, open a PR, and **merge to `main`**.
2. The **Release** workflow runs on every push to `main`.
3. It reads the current `VERSION`, scans commits since the last `chore(release):` commit, and picks a bump:
   - `(major)` or `BREAKING CHANGE` / `type!:` → **major**
   - `feat:` → **minor**
   - `fix:`, `perf:`, `refactor:` → **patch**
   - anything else → **patch**
4. It updates `VERSION` and `CHANGELOG.md`, commits `chore(release): bump version to X.Y.Z` on `main`, and pushes tag `vX.Y.Z`.
5. If the latest commit is already `chore(release):`, the workflow skips (no loop).

## Suggested workflow

```text
feature branch → PR → merge to main → CI releases automatically
```

Optional: use a `dev` branch for day-to-day work and merge `dev` → `main` when ready to release.

## Use this template

Click **Use this template** on GitHub to create a new repo, then start committing. The first merge to `main` with new commits will trigger your first automated release after `0.1.0`.

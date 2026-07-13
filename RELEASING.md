# Releasing Claudette

Releases are cut by pushing a `v*` tag. A GitHub Actions workflow does the rest.

## Cut a release

```bash
# 1. Make sure main is clean and tests / builds pass locally
git checkout main
git pull
./build.sh              # sanity check — should exit 0

# 2. Bump versions in Info.plist if this is a user-facing release:
#    - CFBundleShortVersionString  (e.g. 0.2.0 — the marketing version)
#    - CFBundleVersion             (e.g. 5      — a monotonically-increasing build number)
# Commit + push. Since main requires a PR, do this via a small versioning PR.

# 3. Tag and push
git tag v0.2.0 -m "Claudette 0.2.0"
git push origin v0.2.0
```

## What happens next

The `.github/workflows/release.yml` workflow triggers on any `v*` tag push. On a fresh `macos-15` runner it:

1. Checks out the tagged commit.
2. Runs `./build.sh` — Swift build + `.app` bundle assembly + ad-hoc code sign.
3. Zips `build/Claudette.app` with `ditto` (preserves resource forks and xattrs — plain `zip` breaks macOS bundle signatures).
4. Builds `Claudette-<version>.dmg` via `create-dmg`, with the Claudette icon, a proper installer window layout, and the `/Applications` drop-link — the idiomatic macOS "open the dmg, drag app to Applications" experience.
5. Generates SHA-256 sidecars for both artifacts.
6. Creates a **draft** release named after the tag, with:
   - Auto-generated notes based on commits since the last tag (edit these before publishing).
   - `Claudette-<version>.dmg` + its `.sha256` attached (primary — this is what the README points at).
   - `Claudette.app.zip` + its `.sha256` attached (for users who prefer unzipping or need to script installs).

## Publish

1. Open the draft in [Releases](https://github.com/Avocado-Pty-Ltd/Claudette/releases).
2. Rewrite the auto-notes into human-readable highlights (three lines is often enough).
3. Click **Publish release**.

## Re-run against an existing tag

If a release build fails (flaky runner, network hiccup, etc.), go to Actions → Release → Run workflow, and enter the tag name (e.g. `v0.2.0`). The workflow is idempotent:

- If **no release exists** for the tag, a fresh draft is created.
- If a **draft release** already exists, its assets are replaced in-place with `gh release upload --clobber` — auto-generated notes are preserved so you don't lose any edits you'd started.
- If the release has already been **published**, the workflow refuses to overwrite it (published artifacts are treated as immutable — users may already have downloaded them). Either delete / un-publish it manually, or push a new tag with a fix.

## Notarization (future)

The bundle is currently ad-hoc signed. macOS Gatekeeper will warn users on first launch. For a properly notarized build you'd need:

- An Apple Developer ID Application certificate stored as an encrypted secret.
- A Developer ID Installer certificate (if you also want a `.pkg`).
- `xcrun notarytool submit` after signing.

Not blocking for an early open-source release — the current flow gets people running immediately, they just have to right-click → Open the first time.

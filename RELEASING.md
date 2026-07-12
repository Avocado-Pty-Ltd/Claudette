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

The `.github/workflows/release.yml` workflow triggers on any `v*` tag push. On a fresh `macos-14` runner it:

1. Checks out the tagged commit.
2. Runs `./build.sh` — Swift build + `.app` bundle assembly + ad-hoc code sign.
3. Zips `build/Claudette.app` with `ditto` (preserves resource forks and xattrs — plain `zip` breaks macOS bundle signatures).
4. Generates a SHA256 checksum.
5. Creates a **draft** release named after the tag, with:
   - Auto-generated notes based on commits since the last tag (edit these before publishing).
   - `Claudette.app.zip` attached.
   - `Claudette.app.zip.sha256` attached.

## Publish

1. Open the draft in [Releases](https://github.com/Avocado-Pty-Ltd/Claudette/releases).
2. Rewrite the auto-notes into human-readable highlights (three lines is often enough).
3. Click **Publish release**.

## Re-run against an existing tag

If a release build fails (flaky runner, network hiccup, etc.), go to Actions → Release → Run workflow, and enter the tag name (e.g. `v0.2.0`). It'll re-checkout and re-upload the assets, overwriting the previous ones on the draft.

## Notarization (future)

The bundle is currently ad-hoc signed. macOS Gatekeeper will warn users on first launch. For a properly notarized build you'd need:

- An Apple Developer ID Application certificate stored as an encrypted secret.
- A Developer ID Installer certificate (if you also want a `.pkg`).
- `xcrun notarytool submit` after signing.

Not blocking for an early open-source release — the current flow gets people running immediately, they just have to right-click → Open the first time.

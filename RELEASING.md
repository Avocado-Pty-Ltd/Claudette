# Releasing Claudette

Two ways to cut a release. Pick whichever feels less friction.

## 1. One-click bump (Actions UI)

Go to **Actions → Release → Run workflow** and pick:

- **patch** — bugfix / hygiene / no user-facing change
- **minor** — new features, backwards-compatible
- **major** — breaking changes

The workflow reads the latest existing `vX.Y.Z` tag, bumps the requested component, creates the new tag at the current `main` HEAD, and runs the build. No terminal round-trip.

```
Latest tag       Bump      New tag
v0.1.0     +     patch  →  v0.1.1
v0.1.0     +     minor  →  v0.2.0
v0.1.0     +     major  →  v1.0.0
```

If no `vX.Y.Z` tag exists yet, the first bump lands at `v0.1.0` as a bootstrap.

## 2. Terminal tag push

```bash
git checkout main
git pull
git tag v0.2.0 -m "Claudette 0.2.0"
git push origin v0.2.0
```

The `push: tags: ['v*']` trigger fires the same build. Handy if you want to tag a specific historical commit (`git tag v0.2.0 abcd1234`) instead of `main` HEAD.

## What the workflow does

On a fresh `macos-15` runner (Xcode 16 / Swift 6):

1. Resolves / creates the tag (see above).
2. Checks out the tagged commit.
3. `./build.sh` → `build/Claudette.app` (SwiftPM build + `.app` assembly + ad-hoc code sign).
4. Zips with `ditto` — preserves resource forks / xattrs / signature. Plain `zip` corrupts macOS bundle signatures.
5. Builds `Claudette-<version>.dmg` via `create-dmg` — Claudette icon, installer window layout, `/Applications` drop-link — the idiomatic "open the dmg, drag app to Applications" experience. The step verifies the resulting DMG (`hdiutil verify` + size sanity check) so a corrupted or zero-byte file can't sneak through.
6. `shasum -a 256` sidecars for both artifacts.
7. Creates a **draft** GitHub Release named after the tag, with auto-generated notes from commits since the last tag. Attaches:
   - `Claudette-<version>.dmg` + `.sha256` (primary — the README points at this)
   - `Claudette.app.zip` + `.sha256` (fallback for users who prefer unzipping or need to script installs)

## Publish

1. Open the draft in [Releases](https://github.com/Avocado-Pty-Ltd/Claudette/releases).
2. Rewrite the auto-notes into human-readable highlights (three lines is often enough).
3. Click **Publish release**.

## Re-run a flaky build

If a build fails (runner flake, brew mirror hiccup, etc.):

- Actions → the failed run → **Re-run failed jobs** (top-right). It picks up the same tag and re-runs against it.
- If a **draft release** already exists for the tag, its assets get replaced in-place with `gh release upload --clobber` — the notes you'd started editing are preserved.
- If the release has already been **published**, the workflow refuses to overwrite it (published artifacts are treated as immutable — users may already have downloaded them). Either delete / un-publish it manually, or push a new tag with a fix.

## Notarization (future)

The bundle is currently ad-hoc signed. macOS Gatekeeper will warn users on first launch. For a properly notarized build you'd need:

- An Apple Developer ID Application certificate stored as an encrypted secret.
- A Developer ID Installer certificate (if you also want a `.pkg`).
- `xcrun notarytool submit` after signing.

Not blocking for an early open-source release — the current flow gets people running immediately, they just have to right-click → Open the first time.

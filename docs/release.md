# Release process

End-to-end "cut a new public build" workflow. The whole thing is
automated by [`scripts/release.sh`](../scripts/release.sh) once a few
one-time bits of machine state are in place.

## Contract (six rules)

Any change to `release.sh` must preserve these.

1. **User-triggered only.** Releases start with a human running
   `./scripts/release.sh <version>`. Never auto-trigger.
2. **Bump → build-verify → commit.** After bumping `project.yml` and
   regenerating `Sources/Perch/Resources/Info.plist` via `xcodegen`,
   run a Debug `xcodebuild` to confirm the bumped sources compile. Only
   commit if the build succeeds. On failure, restore both files
   (`git checkout --`) + re-run `xcodegen` and exit non-zero. Never
   leave a half-baked version-bump commit on the branch.
3. **Working tree clean before push.** Pre-flight requires
   `git status --porcelain` empty before bumping; a second check runs
   right after the bump commit. Push only when both pass.
4. **Tag every released version.** After archive + notarize + staple
   succeed, the script creates an annotated tag (`vX.Y.Z` or
   `vX.Y.Z-<pre>` for pre-releases) on the bump commit and pushes it.
5. **Release notes derived from commits by default.** `--generate-notes`
   makes GitHub render notes from commits since the previous tag.
   `--notes-file` is an explicit override for big releases — keep
   commit messages descriptive instead of relying on it.
6. **Every release ships a signed appcast.** The .zip is signed with
   the Sparkle EdDSA key, a new `<item>` is inserted at the top of
   `appcast.xml`, and that file is committed + pushed to `main`
   **after** the GitHub Release exists. Existing installs poll
   `raw.githubusercontent.com/.../main/appcast.xml`, so the feed must
   never reference a download URL that isn't yet live.

## What gets produced

For a given version `X.Y.Z` (optionally with `--prerelease beta`):

- A `release: bump to X.Y.Z (build N)` commit on `main`
- An annotated tag `vX.Y.Z` (or `vX.Y.Z-beta`)
- A `Perch.app` Developer-ID signed (team `T8F5T6HKG8`) and
  notarized + stapled by Apple
- Two GitHub release assets:
  - `Perch-X.Y.Z[-beta].zip` — Sparkle update channel + manual download
  - `Perch-X.Y.Z[-beta].dmg` — drag-to-Applications installer
- A new `<item>` at the top of `appcast.xml`, committed in a follow-up
  `appcast: vX.Y.Z` commit

In-place updates use **Sparkle 2** (see
[`Sources/Perch/Features/Updater/UpdaterService.swift`](../Sources/Perch/Features/Updater/UpdaterService.swift)).
First-launch users still download the DMG; from that build forward,
Sparkle handles all updates.

## One-time setup

These pieces of machine state need to exist on whichever Mac runs the
release. They survive across rebuilds and reboots.

### 1. Tools on `PATH`

```sh
brew install xcodegen gh
```

Xcode itself (provides `xcodebuild`, `codesign`, `notarytool`,
`stapler`, `spctl`) must already be installed.

### 2. `gh` authenticated for the repo

```sh
gh auth login
```

Pick `github.com` → HTTPS or SSH → web flow. Must have push +
release-create permissions on `xVanTuring/Perch`.

### 3. Developer ID Application certificate

The release build is re-signed with **Developer ID Application** at
export time (the build itself uses Apple Development; see comments in
`project.yml`). The cert must exist in the login keychain under team
`T8F5T6HKG8`:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If missing: Xcode → Settings → Accounts → select the team → Manage
Certificates… → `+` → **Developer ID Application**. Make sure the
**private key** for the cert is also in the keychain (the cert without
the key can't sign).

### 4. Developer ID provisioning profile

Originally required because of the iCloud + Push Notifications
entitlements. iCloud sync is currently off and those entitlements are
gone, but `release.sh` still checks for the profile and
`scripts/ExportOptions.plist` still names it, so keep it installed. The profile must
be named exactly **"Perch Profile"** — `scripts/ExportOptions.plist`
looks it up by name.

Create at <https://developer.apple.com/account/resources/profiles/add>:

1. Distribution → Developer ID
2. App ID = `tech.xvanturing.Perch`
3. Pick the Developer ID Application cert (T8F5T6HKG8)
4. Profile name = `Perch Profile` (exact match)
5. Generate → Download → double-click to install

### 5. Sparkle EdDSA key

Sparkle signs every release `.zip` with an EdDSA key. The public half
lives in `project.yml` (→ `Info.plist` as `SUPublicEDKey`); the
private half lives in your **login keychain** under
`https://sparkle-project.org` and is read by `sign_update` at release
time.

Generate it once on this machine:

```sh
xcodegen
xcodebuild -project Perch.xcodeproj -scheme Perch -derivedDataPath .build/release -resolvePackageDependencies
.build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

The tool prints the public key. Copy that string and paste it into
`project.yml` under `SUPublicEDKey`. Then:

```sh
xcodegen
git add project.yml Sources/Perch/Resources/Info.plist
git commit -m "sparkle: set EdDSA public key"
git push
```

**Back up the private key out-of-band** to a password manager or
hardware key:

```sh
.build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_ed_private_key.pem
# move sparkle_ed_private_key.pem to 1Password / hardware key, then:
rm sparkle_ed_private_key.pem
```

⚠️ **Never regenerate the key after the first release ships.** Already-
installed copies of Perch carry the old public key and will reject
updates signed with a different private key — recovery requires shipping
a one-time "manual download only" build with a fresh `SUPublicEDKey`
and telling all existing users to install it by hand.

### 6. `notarytool` keychain profile

```sh
xcrun notarytool store-credentials noticky-notary \
    --apple-id <your@apple.id> \
    --team-id T8F5T6HKG8 \
    --password <app-specific-password>
```

`--password` is **not** your Apple ID's real password. Generate an
app-specific one at <https://appleid.apple.com/account/manage> →
Sign-In and Security → App-Specific Passwords (any label works, e.g.
`notarytool-noticky`). `store-credentials` validates against Apple and
stores the trio in the login keychain under the profile name
`noticky-notary`. The release script never sees the password.

Override the profile name with `NOTARY_PROFILE=foo ./scripts/release.sh ...`.

## Cutting a release

```sh
./scripts/release.sh 1.2.0                          # stable
./scripts/release.sh 1.2.0 --prerelease beta        # prerelease
./scripts/release.sh 1.2.0 --notes-file CHANGELOG.md  # custom release body
./scripts/release.sh 1.2.0 --dry-run                # bump + commit only, no push/build/release
```

The script enforces:

- Run from the repo root (`project.yml` present)
- Working tree clean
- Version matches `X.Y.Z`
- Tag doesn't already exist locally or on origin
- All one-time setup pieces above are present
- `appcast.xml` exists with its `BEGIN-ITEMS` marker
- `SUPublicEDKey` in `Info.plist` is non-empty AND the corresponding
  private key is in the keychain

Pre-flight fails fast (before touching anything) if any check fails.

`CFBundleVersion` is auto-incremented from the current value; you only
pass the short version. The script regenerates the xcodeproj after the
bump.

## Step by step

1. **Pre-flight checks** — tools, certs, profiles, notary, Sparkle
   key, clean WD, no tag conflict, `appcast.xml` marker.
2. **Bump version in `project.yml`** — set `CFBundleShortVersionString`,
   increment `CFBundleVersion`.
3. **Regenerate xcodeproj** via `xcodegen` (writes
   `Sources/Perch/Resources/Info.plist`).
4. **Verify Debug build** — `xcodebuild -configuration Debug build`.
   On failure: revert `project.yml` + `Info.plist`, re-run `xcodegen`,
   exit non-zero. No commit is created.
5. **Commit** the version bump (`project.yml` + `Info.plist`).
6. **Post-commit clean check** — second `git status --porcelain` guard.
7. **Push `main`**.
8. **Archive** the Release configuration into
   `.build/release/Perch.xcarchive` (Apple Development auto-signing
   at archive time).
9. **`-exportArchive`** with `scripts/ExportOptions.plist` re-signs the
   bundle as Developer ID and exports `Perch.app` to
   `.build/release/export/`.
10. **Verify signature** with `codesign --verify --deep --strict`.
11. **Zip** the app with
    `ditto -c -k --sequesterRsrc --keepParent`. The `--sequesterRsrc`
    flag is load-bearing: without it, BSD unzip (Finder Archive
    Utility) leaves AppleDouble `._File` siblings inside the bundle
    and breaks the code-signature seal.
12. **Submit to Apple notary**
    (`xcrun notarytool submit --keychain-profile noticky-notary --wait`)
    — blocks until the verdict comes back, typically 1–5 minutes.
13. **Staple** the notary ticket so Gatekeeper can verify offline.
14. **Re-zip** the stapled app (the pre-notary zip didn't carry the
    ticket).
15. **Build DMG** with a drag-to-Applications symlink.
16. **Notarize + staple** the DMG (a separate submission — DMGs are
    Gatekeeper-checked independently of their contents).
17. **Sparkle-sign** the .zip with `sign_update` and capture the
    EdDSA signature + length.
18. **Insert a new `<item>` at the top of `appcast.xml`** with the
    signature, length, predicted GitHub release download URL,
    `sparkle:version` (build number), `sparkle:shortVersionString`,
    `sparkle:minimumSystemVersion=15.0`, and (for pre-releases)
    `<sparkle:channel>X</sparkle:channel>`.
19. **Tag** the bump commit `vX.Y.Z[-suffix]` and push.
20. **`gh release create`** with `.zip` and `.dmg` as assets and
    `--generate-notes` (or `--notes-file`), marking prerelease when
    applicable.
21. **Commit + push `appcast.xml`** to `main`
    (`appcast: vX.Y.Z`). This **must** happen after `gh release
    create` — otherwise existing installs polling the feed will hit a
    404 for the download URL.

## Troubleshooting

### Debug build verification failed

The script restored `project.yml` + `Info.plist` and exited before
committing. Fix the compile error on `main`, commit it, then re-run
`./scripts/release.sh <version>`. No clean-up needed — the bump was
rolled back.

### "ARCHIVE FAILED" with a signing error

Open the project in Xcode once, let it pick a provisioning profile,
and re-run. If the cert is missing, see one-time setup §3.

### Notarization rejected

```sh
xcrun notarytool log <submission-id> --keychain-profile noticky-notary
```

Common causes:

- An embedded binary isn't hardened-runtime signed (Hardened Runtime
  is enabled in `project.yml`; new framework deps usually inherit it
  automatically).
- A symlink resolves outside the bundle.
- `--timestamp` was missing on a binary (`OTHER_CODE_SIGN_FLAGS:
  --timestamp` is set for Release).

### Tag already exists

```sh
git tag -d vX.Y.Z          # delete local
git push origin :vX.Y.Z    # delete on origin
gh release delete vX.Y.Z   # delete the release if it was made
```

Then re-run.

### "gh release create" 422 Validation Failed

Usually means the tag already has a release. Same fix as above.

### `notarytool history` errors

The keychain profile name is wrong or got corrupted. Re-run
`store-credentials` to recreate it.

### `sign_update` fails or hangs on a Keychain prompt

The first call after a fresh keychain login asks for permission to
read the Sparkle EdDSA private key. Click **Always Allow** so future
release runs don't block.

If `sign_update` reports "No existing signing key found":

- **First-ever release on this machine?** Generate with
  `generate_keys`, paste the public half into `project.yml`.
- **Has shipped before from another machine?** Restore from your
  backup: `generate_keys -f sparkle_ed_private_key.pem`. Do **not**
  regenerate — existing installs will reject anything signed with a
  new key.

### Sparkle reports "The update is improperly signed"

`SUPublicEDKey` in the running app doesn't match the private key that
signed the asset. Either the key in `project.yml` drifted from the
keychain, or someone signed from the wrong machine. Re-sign the asset
with the correct key, edit the `<item>` in `appcast.xml` to use the
new signature, push, and tell affected users to re-check.

## Manual mode

If the script fails midway and you want to finish by hand, the
commands map 1:1 to the steps above. The only irreversible operations
are `git push origin <tag>` and `gh release create` near the end —
everything before that is local and revertable with `git reset`.

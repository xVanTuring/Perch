# Perch — Development

English · [简体中文](./DEV.zh-CN.md)

Developer guide: building, running, and releasing Perch. For the product
overview see [README.md](./README.md); for deep architectural rationale and
recurring gotchas see [CLAUDE.md](./CLAUDE.md).

---

## Architecture

Perch uses an AppKit shell with SwiftUI content (bridged via
`NSHostingController`), backed by Core Data, stored locally only (the
`NSPersistentCloudKitContainer` sync path is switched off — see
[CLAUDE.md → iCloud sync is off](./CLAUDE.md#icloud-sync-is-off-since-2026-10-28)). No Dock icon, lives in
the menu bar (`LSUIElement`).

- Lightweight Core Data migration is always on
  (`shouldInferMappingModelAutomatically`).
- Versioned model: `Persistence/Schema/SchemaV{N}.swift` + a `CoreDataSchema`
  registry, with `SchemaVersion.current` pointing at the active version.
- On store load failure, Perch **never silently nukes the database** — it
  backs up the sqlite + shm + wal triple to `~/Desktop/Perch-Recovery-{ts}/`,
  shows a critical NSAlert, and quits.

For why an AppKit shell instead of pure SwiftUI App, why a programmatic Core
Data model instead of `.xcdatamodeld`, and recurring gotchas, see
[CLAUDE.md](./CLAUDE.md).

---

## Requirements

- macOS 15.0+
- To build: Xcode 16+, Swift 5.0+, [xcodegen](https://github.com/yonaskolb/XcodeGen)
- To release: Apple Developer account (team ID `T8F5T6HKG8`) + Developer ID certificate

---

## Project layout

```
Sources/Perch/
├─ App/                  # Entry point (custom main), AppDelegate, MenuBarController
├─ Persistence/          # PersistenceController, Note, NoteGroup
│  └─ Schema/            # Versioned Core Data schemas
├─ Features/
│  ├─ Floating/          # Floating sticky notes (FloatingNoteWindow, StickyPalette)
│  ├─ Notes/             # Editors (PlainTextEditor, MarkdownNoteEditor)
│  ├─ Capture/           # Global-hotkey quick capture + AX/clipboard sources
│  ├─ Manager/           # Manager window (NSOutlineView sidebar)
│  ├─ Settings/          # Settings window (NSTabViewController + SwiftUI tabs)
│  └─ IO/                # Import / export / backup
└─ Resources/            # Info.plist, entitlements, AppIcon
scripts/                 # release.sh, ExportOptions.plist
project.yml              # xcodegen project definition
```

---

## Build & run (development)

```sh
# 1. Generate Perch.xcodeproj (.xcodeproj is gitignored, regenerate after
#    pulling or after adding/moving files).
xcodegen

# 2. Debug build
xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Debug build

# 3. Run the binary directly so we can capture stderr (helpful for menubar apps)
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*Perch*/Build/Products/Debug/Perch.app/Contents/MacOS/Perch" \
    | head -1)
pkill -f "Perch.app/Contents/MacOS/Perch" 2>/dev/null
"$APP" > /tmp/perch.log 2>&1 &
disown

# 4. Quit cleanly (so applicationShouldTerminate runs and persists window state)
osascript -e 'tell application "Perch" to quit'
```

`⌘R` from Xcode works too, but during development the CLI workflow is preferred —
it makes `tail /tmp/perch.log` viable, which matters because LSUIElement apps
have flaky output in Console.app / `log show`.

---

## DEBUG-only helpers

DEBUG builds expose two schema helpers:

- **`Run migration self-test`** (Settings → General → Data) — validates that
  lightweight migration handles your model changes before tagging a release.
- **`Initialize Cloud schema (Development)`** (Settings → iCloud Sync, only
  while sync is on — the tab is currently hidden) — pushes the schema to CloudKit
  Development. Promoting Development → Production still has to happen manually
  in [CloudKit Console](https://icloud.developer.apple.com) — see
  [CLAUDE.md → Schema → CloudKit deployment workflow](./CLAUDE.md#schema--cloudkit-deployment-workflow).

---

## Packaging & release

`scripts/release.sh` is a single-shot script that does the entire chain:
archive → exportArchive (Developer ID re-sign) → notarize app → staple → build
DMG → notarize DMG → staple. Output lands in `dist/v<VERSION>/`:

```
dist/v1.0.0/
├─ Perch.app
├─ Perch-1.0.0.zip
└─ Perch-1.0.0.dmg
```

The script is idempotent — re-runs are safe. Total wall time is ~5–15 minutes
(notarization queue time dominates).

Full step-by-step, one-time setup, and troubleshooting live in
[`docs/release.md`](./docs/release.md) — the sections below are the TL;DR.

### One-time setup (per machine)

1. **Developer ID Application certificate** in your keychain
   (team `T8F5T6HKG8` — Shenzhen Zhiqishidai Technology):

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   If missing: Xcode → Settings → Accounts → Manage Certificates →
   `+` → Developer ID Application, or have an Admin issue + share the `.p12`.

2. **Developer ID provisioning profile** named exactly `Perch Profile`
   (`scripts/ExportOptions.plist` looks it up by name).

   Create it at https://developer.apple.com/account/resources/profiles/add:
   Distribution → Developer ID → App ID `tech.xvanturing.Perch` →
   pick the Developer ID Application cert → name it `Perch Profile` →
   Generate → Download → double-click to install.

   > Originally required because the entitlements included iCloud + Push
   > Notifications. iCloud sync is currently off and those entitlements are
   > gone, but `release.sh` still checks for the profile and
   > `ExportOptions.plist` still names it — keep it installed.

3. **notarytool credentials** stored in your keychain. Generate an app-specific
   password at https://appleid.apple.com → Sign-In and Security →
   App-Specific Passwords:

   ```sh
   xcrun notarytool store-credentials "noticky-notary" \
     --apple-id  "<your-apple-id>" \
     --team-id   "T8F5T6HKG8" \
     --password  "<app-specific-password>"
   ```

   The script defaults to keychain profile `noticky-notary`; override with
   `NOTARY_PROFILE=foo ./scripts/release.sh`.

### Per release

```sh
./scripts/release.sh
```

After it completes:

```sh
# Mount the DMG → drag to /Applications → right-click Open the first time
open dist/v1.0.0/Perch-1.0.0.dmg

# Sanity-check version / hotkey / Settings, then tag and push
git tag v1.0.0
git push --tags
# Then upload Perch-1.0.0.dmg to GitHub Releases or your distribution channel.
```

### Bumping the version

The version is read from `CFBundleShortVersionString` in `project.yml`. After
editing it, re-run `xcodegen` to regenerate the Xcode project before invoking
`release.sh`.

### CloudKit schema deployment (separate flow)

> **Inactive while iCloud sync is off** (`CloudKitConfig.syncAvailable = false`,
> no CloudKit entitlements): a schema bump only needs step 1. The rest applies
> again once sync comes back.

⚠️ Release builds use `aps-environment=production`, so end users hit your
**Production** CloudKit environment. If a release bumps the schema (i.e.
`SchemaVersion.current` changes), you **must** push the new schema to
Production *first*, otherwise sync will silently drop the new fields.

Full procedure: [CLAUDE.md → Schema → CloudKit deployment workflow](./CLAUDE.md#schema--cloudkit-deployment-workflow).
TL;DR:

1. DEBUG build → Settings → General → `Run migration self-test` to verify.
2. DEBUG build → Settings → iCloud Sync → `Initialize Cloud schema (Development)`.
3. Open [CloudKit Console](https://icloud.developer.apple.com), promote the
   schema from Development → Production manually.
4. Then ship the release.

⚠️ CloudKit's Production schema is **append-only** — once a field/type is
deployed, it can never be removed. Add carefully.

---

## License

© 2026 xVanTuring.

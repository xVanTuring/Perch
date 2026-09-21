# Perch — macOS sticky notes

AppKit shell + SwiftUI content via `NSHostingController`, Core Data backed,
xcodegen-managed Xcode project. macOS 15+, Swift 5.0, `LSUIElement = true`
(menubar app, no Dock icon, no main menu in menu bar).

## Build & run

```sh
# Regenerate Perch.xcodeproj from project.yml (after adding/moving files,
# or pulling from a fresh checkout — .xcodeproj is gitignored).
xcodegen

# Build (Debug)
xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Debug build 2>&1 \
    | grep -E "(error:|BUILD )" | tail -10

# Run binary directly (so we can capture stderr, see "GUI debug" below)
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*Perch*/Build/Products/Debug/Perch.app/Contents/MacOS/Perch" \
    2>/dev/null | head -1)
pkill -f "Perch.app/Contents/MacOS/Perch" 2>/dev/null
"$APP" > /tmp/perch.log 2>&1 &
disown

# Quit cleanly (so applicationShouldTerminate runs)
osascript -e 'tell application "Perch" to quit'
```

## Source layout

```
Sources/Perch/
├─ App/                  # PerchApp (SwiftUI App), AppDelegate, MenuBarController
├─ Persistence/          # PersistenceController (programmatic NSManagedObjectModel),
│                        # Note, NoteGroup
├─ Features/
│  ├─ Floating/          # Sticky note windows (StickyPanel, FloatingNoteWindow,
│  │                       StickyPalette)
│  ├─ Notes/             # MarkdownEngineNoteEditor (the one editor), NoteFormatMenu
│  │                       (right-click Format), Images/ (see "Note images")
│  ├─ Capture/           # Quick-capture window + Carbon global hotkey
│  ├─ Manager/           # Centralized management window (NavigationSplitView)
│  └─ Settings/          # NSTabViewController-based settings + SwiftUI tabs
├─ MCP/                  # Local MCP server (Agent access to notes) — see docs/mcp.md
└─ Resources/            # Info.plist, entitlements
```

## Architectural choices

- **AppKit shell, SwiftUI inside**. `NSWindow` / `NSPanel` for system behaviors
  (window levels, Spaces, menubar, NSStatusItem). SwiftUI for content via
  `NSHostingController`. **Don't fight this** — full SwiftUI lifecycle (no
  `@NSApplicationDelegateAdaptor`-only) loses too much AppKit access.
- **Programmatic Core Data model** (no `.xcdatamodeld` bundle), versioned via
  `Persistence/Schema/SchemaV{N}.swift` + `CoreDataSchema` registry. Each schema
  version has its own builder; `SchemaVersion.current` is the head. Lightweight
  migration is on (`shouldInferMappingModelAutomatically`) — handles 99% of
  changes (add/remove fields, renames with `renamingIdentifier`, add entities).
  Load failure no longer nukes — backs up sqlite/shm/wal to `~/Desktop/
  Perch-Recovery-{ts}/` and shows critical NSAlert before quitting.
  **Adding a new schema version**: copy `SchemaV1.swift` → `SchemaV2.swift`,
  edit only V2, add `case v2` to `SchemaVersion`, set `current = .v2`.
  **Never edit a published version** — its hash is baked into user sqlites.

## Schema → CloudKit deployment workflow

When bumping `SchemaVersion.current` (e.g., V1 → V2):

1. **Local migration**: lightweight migration handles user sqlites automatically
   on first launch with the new build. No user action.
2. **Verify the migration code path** before tagging release:
   Settings → iCloud Sync → "Run migration self-test" (DEBUG build).
   Builds a synthetic prior version, writes sample data, migrates forward,
   asserts data preserved. Pass = lightweight migration handles your changes.
   Fail = either your changes need a custom mapping model, or `SchemaMigrationTester`
   itself needs a new synthetic case for the kind of change you made.
3. **Push schema to CloudKit Development**:
   Settings → iCloud Sync → "Initialize Cloud schema (Development)".
   `NSPersistentCloudKitContainer.initializeCloudKitSchema()` walks the model
   and creates/updates record types in the Dev environment of your CloudKit
   container. After success, the deployed-version label updates to the
   current `SchemaVersion`. The "Local schema differs from last push" warning
   reminds you when the field is stale.
4. **Promote Development → Production** in the CloudKit Console
   (https://icloud.developer.apple.com → your container → Schema → Deploy
   Schema Changes). **This is the only step Perch cannot do programmatically**
   — it must happen via the web UI per Apple's CloudKit deployment model.
   Deploying anything destructive (removing fields/types from Production) is
   irreversible without losing all user cloud data.
5. **CloudKit production schema is append-only.** You can add fields/record
   types in V2; you can never remove them once deployed to Production.
   Unused fields stay in Production's schema forever.
- **`Note.isPinned` doubles as "auto-show on launch"**. `applicationShouldTerminate`
  sets `floating.isTerminating = true` so `windowWillClose` skips clearing it.
- **xcodegen as project file authority**. `project.yml` is tracked, `*.xcodeproj/`
  ignored. Adding a new `.swift` file? It's auto-globbed; just rerun `xcodegen`.

## Settings storage

- UserDefaults keys live in `SettingsKey` enum (`Sources/Perch/Features/Settings/SettingsView.swift`).
- Don't sprinkle string keys; add to the enum.
- `floatOnTop` is owned by `FloatingNotesRegistry`, not @AppStorage (it has
  side effects: must update all open windows on toggle).

## MCP server (Agent access to notes)

Local, hand-rolled JSON-RPC-over-HTTP server (`Sources/Perch/MCP/`, no SDK
dependency), same approach as uni-reader's `Sources/MCP/`. Off by default;
toggled in Settings → Agent (`MCPServerTab`). All mutations route through
`MCPFacade` → the same `FloatingNotesRegistry`/`Note`/`NoteGroup` methods the
GUI uses — an agent's delete is a normal soft-delete to Trash, "pin" really
opens a sticky window, etc. Write-tier tools are gated centrally in
`MCPCatalog.call` behind `SettingsKey.mcpAllowWrite` (default off). Full tool
list and setup instructions: [`docs/mcp.md`](docs/mcp.md).

**Gotcha**: `FloatingNotesRegistry.delete/restore/archive/unarchive` defer
their actual field writes by one runloop tick (`DispatchQueue.main.async`) —
see its own comments. `MCPFacade` must await its own
`DispatchQueue.main.async` continuation (`waitForDeferredRegistryWrite()`)
after calling into those before reading the note back, or the tool result
reports stale pre-mutation state.

## Note images

Pasted images and `![alt](https://…)` images, rendered by the engine through one
`EmbeddedImageProvider` (`NoteImageProvider`, `Features/Notes/Images/`).

- **Reference in the note text**: `![[name|UUID]]` (engine-native; a trailing
  `|300` sets the display width). The UUID is the `NoteImage.id`. The raw text is
  what MCP agents and titles see (`Note.stripMarkdownMarkers` reduces it to `name`).
- **Storage**: Core Data entity `NoteImage` (SchemaV5) with `data` on external binary
  storage, so it syncs through CloudKit as a CKAsset. There is **no relationship** to
  `Note` — references live only in the text. `ownerNoteID` is a cleanup hint, not a key.
- **Remote images** (`RemoteImageLoader`): https only (ATS blocks http), cached in
  `~/Library/Caches/tech.xvanturing.Perch/RemoteImages`. The engine's image API is
  synchronous, so a miss returns nil and the provider bumps `revision` when the
  download lands; the editor observes it and the engine re-fetches.
- **Paste** (`NoteImagePaste`, wired to the engine's `onPasteImage`): image files win;
  a bitmap flavor counts only when the pasteboard has no real text (Excel cells carry
  both) — a lone URL is not "text"; PDF flavors are ignored on purpose.
- **Cleanup happens only when a note is permanently deleted** — the four paths in
  `FloatingNotesRegistry` (`deletePermanently`, `emptyTrash`, `clearAll`,
  `purgeExpiredTrash`). Take `candidates(for:)` **before** deleting, call
  `removeUnreferenced` **after** saving. Candidates = images referenced in those notes'
  text + images whose `ownerNoteID` is one of them; an image is deleted only if no
  remaining note (trash and archive included) still references it.
  **Do not add a periodic whole-library orphan sweep**: on a fresh device the image
  records can arrive before the notes that reference them, the sweep would delete them,
  and the deletion syncs out and cannot be undone. Images orphaned by editing stay until
  their owner note is deleted.
- **Backups must carry the external data**: Core Data keeps large blobs in a hidden
  `.<store>_SUPPORT/_EXTERNAL_DATA` folder next to the sqlite. `NoteIO.exportAllSQLite`
  turns external storage off for its export model (single self-contained file);
  `importSQLite` and `PersistenceController.backupStore` copy that folder. Anything new
  that copies the store files needs the same.
- **CloudKit**: SchemaV5 adds a record type. Before shipping a release, run Settings →
  iCloud Sync → "Initialize Cloud schema (Development)" from a Debug build, then deploy
  Development → Production in the CloudKit Console. Otherwise the release build's
  `NoteImage` uploads are silently dropped.
- **Not done yet**: dragging image files into a note (the engine's text view registers
  file-drag types itself and has no hook — needs an engine change), and Markdown export
  including images (should export to a folder with the images beside the notes).

## Window framing

- Sticky positions/sizes persisted on each `Note` (`frameX/Y/W/H + hasSavedFrame`).
- `windowDidMove`/`windowDidResize` debounce 250ms before write.
- `windowWillClose` cancels pending + flushes synchronously.
- On show, restore saved frame only if it intersects a visible `NSScreen`;
  otherwise cascade from screen center.

## GUI debug (no UI access)

```sh
# stderr capture is reliable; unified `log show` drops NSLog from LSUIElement apps.
"$APP" > /tmp/perch.log 2>&1 &
# Add NSLog("Perch <event>: …") at suspect spots.

# For window state: enumerate NSApp.windows and log frame/isVisible/level.
# For schema/data state, inspect the sqlite directly:
sqlite3 "$HOME/Library/Application Support/Perch/Perch.sqlite" \
    "SELECT Z_PK, ZISPINNED, substr(ZCONTENT,1,40) FROM ZNOTE;"

# Crash reports: ~/Library/Logs/DiagnosticReports/Perch-*.ips
```

## Repeating gotchas (pointers — full notes in `~/.claude/projects/.../memory/`)

- **Do not delete a Core Data object inline while a SwiftUI `@ObservedObject`
  watches it** — guard `body` with `if note.isDeleted { EmptyView() }` AND
  defer `context.delete()` to next runloop tick.
- **`NSPredicate(format: "x == YES")` does not work in Swift** for boolean
  attributes — must be `NSPredicate(format: "x == %@", NSNumber(value: true))`.
- **`SourceKit "Cannot find type"` errors on every save are noise** for this
  project (programmatic model, single-module). Trust `xcodebuild` output, not
  inline diagnostics.
- **`window.performClose(nil)` is a no-op on borderless windows** (no
  `.closable` styleMask). Use `window.close()` directly.
- **`NSHostingController` shrinks its host `NSWindow` to the SwiftUI view's
  intrinsic size**. After assigning `contentViewController = host`, always
  call `window.setContentSize(...)` once. Don't also set SwiftUI `.frame()`
  or `host.preferredContentSize` — three constraints triggers Auto Layout
  infinite loop crash.
- **Entry point is AppKit, not SwiftUI App**. `AppDelegate` carries `@main`
  and a custom `static func main()` that runs `NSApplication.shared`. We
  do **not** use `@main struct ...: App { var body: some Scene { ... } }`
  because that requires at least one Scene, and `Settings { ... }` scene
  hijacks ⌘, via a private mechanism that beats `NSApp.mainMenu` key
  equivalent dispatch (verified: replacing mainMenu still showed SwiftUI's
  empty Settings window on ⌘,). `WindowGroup`/`Window` auto-create
  visible windows, also unwanted. So no SwiftUI App lifecycle at all.
- **Settings window is fully AppKit** (`SettingsWindowController` +
  `AnimatedSettingsTabController: NSTabViewController`). ⌘, comes from a
  hand-rolled `NSApp.mainMenu` Settings item — LSUIElement hides the
  menu bar but key equivalents still dispatch. Animation: `NSAnimationContext.
  runAnimationGroup { ctx.allowsImplicitAnimation = true; window.animator().
  setFrame(...) }` with top-anchor (`origin.y -= delta`). This matches
  sindresorhus/Settings + every other open-source mac app that wants the
  System Settings.app feel — see CLAUDE.md commits for the search trail.
  Each pane's `NSHostingController.sizingOptions = .preferredContentSize`
  bridges SwiftUI `.frame(...)` to `NSViewController.preferredContentSize`,
  so the tab controller can read the target size.

## Releases

`scripts/release.sh <version>` does the whole chain: pre-flight checks →
bump `CFBundleShortVersionString` + `CFBundleVersion++` → xcodegen → Debug
build verify → commit → push → archive → exportArchive (Developer ID
re-sign) → notarize app → staple → DMG → notarize DMG → staple →
Sparkle-sign zip → insert appcast item → tag + push → `gh release create`
(.zip + .dmg) → commit + push appcast.

Output: `dist/v<VERSION>/{Perch.app, .zip, .dmg}`. Full step-by-step,
one-time setup, and troubleshooting in [`docs/release.md`](docs/release.md).

Per-release entry point:

```sh
./scripts/release.sh 1.2.0                    # stable
./scripts/release.sh 1.2.0 --prerelease beta  # beta channel item in appcast
./scripts/release.sh 1.2.0 --dry-run          # bump+verify+commit only, no push/build
```

Allow ~5–15 min: build is fast, notarization waits on Apple's queue.

**Sparkle 2** ships in-place updates after the first install. See
[`Sources/Perch/Features/Updater/UpdaterService.swift`](Sources/Perch/Features/Updater/UpdaterService.swift)
+ `Settings → Updates`. Appcast feed:
`https://raw.githubusercontent.com/xVanTuring/Perch/main/appcast.xml`.
EdDSA public key lives in `project.yml`'s `SUPublicEDKey`; private key in
login keychain (`https://sparkle-project.org`).  Never regenerate the key
after the first Sparkle-enabled build ships — existing installs will
reject anything signed with a new key.

**CloudKit production deployment is independent** — see "Schema → CloudKit
deployment workflow" above. The Release build's entitlement uses
`aps-environment=production`, so end users on this build hit your CloudKit
**Production** environment. Make sure schema is deployed to Production in
CloudKit Console *before* shipping a release that adds new fields, or sync
will silently drop them.

## Commits

Per Perch-specific authorization (see memory `feedback_noticky_commits_autonomous.md`),
commits are made autonomously by Claude after each semantically complete change.
One change = one commit. No auto-push, no destructive git ops without user OK.

# Perch — 开发文档

[English](./DEV.md) · 简体中文

开发指南：构建、运行与发布 Perch。产品介绍见 [README.zh-CN.md](./README.zh-CN.md)；
更深入的架构讲解与重复踩过的坑见 [CLAUDE.md](./CLAUDE.md)。

---

## 架构

AppKit 外壳 + SwiftUI 内容（`NSHostingController` 桥接），Core Data 持久化，
只存本地（`NSPersistentCloudKitContainer` 同步已关闭，见 [CLAUDE.md → iCloud sync is off](./CLAUDE.md#icloud-sync-is-off-since-2026-10-28)）。无 Dock 图标，常驻菜单栏
（`LSUIElement`）。

- Core Data 启用 lightweight migration（`shouldInferMappingModelAutomatically`）。
- 模型版本化：`Persistence/Schema/SchemaV{N}.swift` + `CoreDataSchema` 注册表，
  `SchemaVersion.current` 指向当前版本。
- 加载失败时**不再静默销毁** — 会把 sqlite + shm + wal 三件套备份到
  `~/Desktop/Perch-Recovery-{ts}/` 后弹出 NSAlert 再退出。

为什么用 AppKit 外壳而不是 SwiftUI App、为什么不用 `.xcdatamodeld`、重复踩过的坑等，
见 [CLAUDE.md](./CLAUDE.md)。

---

## 系统要求

- macOS 15.0+
- 自行构建：Xcode 16+、Swift 5.0+、[xcodegen](https://github.com/yonaskolb/XcodeGen)
- 发布：Apple Developer 账号（团队 ID `T8F5T6HKG8`）+ Developer ID 证书

---

## 项目结构

```
Sources/Perch/
├─ App/                  # PerchApp（自定义 main）、AppDelegate、MenuBarController
├─ Persistence/          # PersistenceController、Note、NoteGroup
│  └─ Schema/            # 版本化 Core Data schema
├─ Features/
│  ├─ Floating/          # 浮窗便签（FloatingNoteWindow、StickyPalette）
│  ├─ Notes/             # 编辑器（PlainTextEditor、MarkdownNoteEditor）
│  ├─ Capture/           # 全局快捷键速记 + AX/剪贴板取材
│  ├─ Manager/           # 中央管理窗口（NSOutlineView 侧栏）
│  ├─ Settings/          # 设置窗口（NSTabViewController + SwiftUI tabs）
│  └─ IO/                # 导入 / 导出 / 备份
└─ Resources/            # Info.plist、entitlements、AppIcon
scripts/                 # release.sh、ExportOptions.plist
project.yml              # xcodegen 项目定义
```

---

## 构建与运行（开发）

```sh
# 1. 生成 Perch.xcodeproj（.xcodeproj 不入库，每次拉代码或加文件后都要跑）
xcodegen

# 2. Debug 构建
xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Debug build

# 3. 直接跑产物（保留 stderr，方便调菜单栏 App）
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*Perch*/Build/Products/Debug/Perch.app/Contents/MacOS/Perch" \
    | head -1)
pkill -f "Perch.app/Contents/MacOS/Perch" 2>/dev/null
"$APP" > /tmp/perch.log 2>&1 &
disown

# 4. 退出（走 applicationShouldTerminate，会持久化窗口现场）
osascript -e 'tell application "Perch" to quit'
```

直接在 Xcode 里 `⌘R` 也行，但 Debug 时建议走命令行 — 方便 tail `/tmp/perch.log`，
菜单栏 App 在 Console.app / `log show` 里 NSLog 抓不到。

---

## DEBUG 专属工具

DEBUG build 有两个 schema 工具：

- **`Run migration self-test`**（Settings → 通用 → 数据）— 发版前验证 lightweight migration 能吃下你的模型改动。
- **`Initialize Cloud schema (Development)`**（Settings → iCloud Sync，同步开着时才有，目前这个页隐藏）— 自动 push schema 到 CloudKit
  Development。生产环境 promote 仍需在 [CloudKit Console](https://icloud.developer.apple.com)
  手动部署 — 见 [CLAUDE.md → Schema → CloudKit deployment workflow](./CLAUDE.md#schema--cloudkit-deployment-workflow)。

---

## 打包发布

`scripts/release.sh` 是一键脚本：archive → exportArchive (Developer ID 重签) →
公证 .app → staple → 打 DMG → 公证 DMG → staple。产物到 `dist/v<VERSION>/`：

```
dist/v1.0.0/
├─ Perch.app
├─ Perch-1.0.0.zip
└─ Perch-1.0.0.dmg
```

脚本是幂等的，重跑安全。整个链路 5–15 分钟（公证排队为主）。

完整步骤、一次性配置与排错见 [`docs/release.md`](./docs/release.md) —
下面是关键步骤的 TL;DR。

### 一次性配置（每台机器）

1. **Developer ID Application 证书** 在 keychain 里
   （团队 `T8F5T6HKG8` — Shenzhen Zhiqishidai Technology）：

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   缺失则到 Xcode → Settings → Accounts → Manage Certificates →
   `+` → Developer ID Application 安装，或让 Admin 颁发并发 `.p12` 给你。

2. **Developer ID 配置文件**，名字必须是 `Perch Profile`
   （`scripts/ExportOptions.plist` 按名字 lookup）。

   到 https://developer.apple.com/account/resources/profiles/add 创建：
   Distribution → Developer ID → App ID `tech.xvanturing.Perch` →
   选 Developer ID Application 证书 → 命名 `Perch Profile` →
   Generate → Download → 双击安装。

   > 当初是因为 entitlements 里有 iCloud + Push Notifications 才必须要 profile。
   > 现在 iCloud 同步已关闭、这些 entitlements 已删，但 `release.sh` 仍检查 profile，
   > `ExportOptions.plist` 仍按名字引用它 —— 继续保持安装。

3. **notarytool 凭据** 存进 keychain。先到 https://appleid.apple.com →
   Sign-In and Security → App-Specific Passwords 生成专用密码：

   ```sh
   xcrun notarytool store-credentials "noticky-notary" \
     --apple-id  "<your-apple-id>" \
     --team-id   "T8F5T6HKG8" \
     --password  "<app-specific-password>"
   ```

   脚本默认找 keychain profile `noticky-notary`，可用
   `NOTARY_PROFILE=foo ./scripts/release.sh` 覆盖。

### 单次发布

```sh
./scripts/release.sh
```

跑完后：

```sh
# 挂 DMG → 拖到 /Applications → 首次右键 Open
open dist/v1.0.0/Perch-1.0.0.dmg

# 验证版本 / 快捷键 / Settings 能开
# 没问题就打 tag 推上游
git tag v1.0.0
git push --tags
# 然后把 Perch-1.0.0.dmg 上传到 GitHub Releases 或自有渠道
```

### 修改版本号

版本号读自 `project.yml` 的 `CFBundleShortVersionString`。改完跑 `xcodegen` 重新生成
工程文件，再走 `release.sh`。

### CloudKit schema 发布（独立流程）

> **iCloud 同步关闭期间不适用**（`CloudKitConfig.syncAvailable = false`，没有 CloudKit
> entitlements）：改 schema 只需要第 1 步。同步恢复后整段重新适用。

⚠️ Release build 的 entitlement 是 `aps-environment=production`，老用户安装新版后
直接命中 CloudKit **Production** 环境。如果新版本动了 schema（`SchemaVersion.current`
升号），**必须先**把 schema 部署到 Production，否则同步会静默丢字段。

完整流程见 [CLAUDE.md → Schema → CloudKit deployment workflow](./CLAUDE.md#schema--cloudkit-deployment-workflow)。
关键步骤：

1. DEBUG build → Settings → 通用 → `Run migration self-test` 验证。
2. DEBUG build → Settings → iCloud Sync → `Initialize Cloud schema (Development)`。
3. 手动到 [CloudKit Console](https://icloud.developer.apple.com) 把 schema 从
   Development promote 到 Production。
4. 再发版。

⚠️ CloudKit production schema 是 **append-only** — 一旦部署就拿不掉，加新字段只进不出。

---

## License

© 2026 xVanTuring.

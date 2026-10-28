# Perch 待办清单

完成一项后改 `[ ]` → `[x]`(保留行,git 历史可追)。每项后括号是简要动机/难度 hint。

## A. 代码里已有 stub(用户在 UI 里能看到"未实现"提示)

- [x] Settings → **Shortcuts** 可自定义全局热键(Quick Capture)。menu / window 派发的 macOS 标准键(⌘N/⌘W/⌘Q/⌘,/⌘⇧0/⌘D)继续保持只读。基于 sindresorhus/KeyboardShortcuts 库
- [x] Settings → **Notes** 补 tab 内容:默认便签颜色 / 默认字号(12-24,实时同步)/ 默认窗口尺寸(Small/Medium/Large)/ 默认进编辑态 toggle
- [x] Settings → **iCloud Sync** 真正接入(`NSPersistentCloudKitContainer` + Sync UI/状态展示 + 实时同步)。已验证中国区 iCloud (gateway.icloud.com.cn) 跑通。坑:**macOS 用 `com.apple.developer.aps-environment`,不是 iOS 的 `aps-environment`**,写错 codesign 静默丢 key,数据库 subscription 创建失败把整个 setup 链拖死

- [ ] **跨设备同步重新设计**:iCloud 同步 2026-10-28 下线(`CloudKitConfig.syncAvailable = false`,entitlements 已删),原因是 CloudKit 容器绑定开发者账号,换账号后读不到旧容器。候选:换新容器重开 CloudKit / 同步文件夹 / WebDAV。iCloud Drive 方案见 [docs/icloud-drive-sync.md](docs/icloud-drive-sync.md),第一、二阶段已完成(2026-10-28,未发版),第三阶段(不重叠修改的自动合并)待做。重开 CloudKit 时开关换新 key(见 CLAUDE.md)

## B. 体验类(常见便签 app 有 / 用户可能想要)

- [x] **拖拽笔记到分组**(目前只能右键 Move to Group)—— Manager sidebar `.onDrag` + `.onDrop`,多选拖动跟着 selection 走
- [x] **批量操作扩展**:多选后批量改色(6 色板)/ 批量 Pin/Unpin / 批量打开为浮窗(≤8 条防糊屏)
- [x] **导入 / 导出** —— 右键 Manager 选中便签 Export(单条 .md / 多条到目录);File menu Import / Backup / Restore。整库 backup 用 JSON 单文件而非 zip(等附件支持再换 zip)
- [ ] **自定义颜色** 入口(目前固定 6 色板)
- [ ] **字体大小调整**(单条 / 全局两套?)
- [ ] **搜索结果高亮**(`.searchable` 已经过滤,但匹配文本不高亮)
- [x] **回收站保留天数自定义** —— Settings → General Stepper(7-365 天,默认 30)
- [ ] **强制暗 / 亮主题**(目前跟随系统)
- [ ] **Markdown 实时分屏预览**(目前是渲染 ↔ 编辑双态切换)
- [ ] **附件 / 图片支持**(当前纯文本)
- [ ] **提醒 / 闹钟**(笔记有时间触发)
- [ ] **多窗口同时编辑同一笔记**(目前 registry 强制一条笔记一个浮窗)

## C. 分发 / 上架

- [x] **Core Data versioned model** —— `Persistence/Schema/SchemaV{N}.swift` + `CoreDataSchema` 注册表;model 写 `versionIdentifiers=["v1"]`;lightweight migration 一直开;失败兜底改成"备份 sqlite 三件套到桌面 + NSAlert + quit",不再静默 nuke
- [ ] **Developer ID 代码签名** + **notarytool 公证**(目前 Debug 直接跑)
- [ ] **DMG 打包脚本**
- [ ] **Sparkle 自更新框架**
- [ ] **Mac App Store 版本**:需要把 AX 抓取重做成独立 XPC service,因为 MAS 强制 sandbox(`Perch.entitlements:13` 注释)

## D. 已知 polish / 非功能 bug

- (暂无追踪,出现新 bug 再加在这一节)

---

## 已完成(参考)

近期完成的功能不在此重复 —— 见 `git log --oneline` 看完整列表。

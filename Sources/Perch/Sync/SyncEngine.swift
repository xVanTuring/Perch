import AppKit
import CoreData

/// 通过同步文件夹(默认 iCloud 云盘/Perch)同步笔记、分组、图片。
/// 设计见 docs/icloud-drive-sync.md;合并规则在 `Sync/Core/SyncMerge.swift`。
///
/// - 导出:监听保存,2 秒内的多次保存合成一次;拿本地值和上次合并结果(`base`)比,
///   不一样的字段才打新时间戳、写进本机文件夹。导入写进去的值和 `base` 一样,不会被写回去。
/// - 导入:文件夹变化(FSEvents)、启动、唤醒、每 5 分钟。只读大小或修改时间变了的文件,
///   并发下载;合并后写进 Core Data。
/// - 线程:Core Data 和同步状态只在主线程碰;同步文件夹的读写在 `io` 队列。
final class SyncEngine: ObservableObject {
    private(set) static var shared: SyncEngine?

    enum Phase: Equatable {
        case off
        case starting
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var devices: [SyncFolder.DeviceInfo] = []
    /// 本次运行中生成的冲突副本数。
    @Published private(set) var conflictCopiesCreated = 0
    /// 本机的设备 ID(设备列表里标出「本机」)。同步没在运行时为 nil。
    @Published private(set) var ownDeviceID: String?
    /// 失败原因是没有访问权限:设置页额外给一个打开「隐私与安全性」的按钮。
    @Published private(set) var needsPermission = false

    private let context: NSManagedObjectContext
    private weak var registry: FloatingNotesRegistry?
    private let io = DispatchQueue(label: "tech.xvanturing.Perch.sync.io", qos: .utility)

    private var folder: SyncFolder?
    private var identity: SyncDeviceIdentity?
    private var state: SyncLocalState?
    private var clock = HybridLogicalClock(deviceID: "")
    private var watcher: SyncFolderWatcher?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastDeviceInfoWrite: Date?

    private var pendingIDs: [SyncFolder.Kind: Set<UUID>] = [:]
    private var pendingDeletionScan = false
    private var exportWork: DispatchWorkItem?
    private var importWork: DispatchWorkItem?
    private var importInFlight = false
    private var importRequestedAgain = false
    /// stop() / restart() 之后,还在路上的后台结果作废。
    private var generation = 0

    private init(context: NSManagedObjectContext, registry: FloatingNotesRegistry) {
        self.context = context
        self.registry = registry
    }

    /// AppDelegate 启动时调一次。同步没开就只建对象(设置页要观察它),不做任何事。
    static func setUp(context: NSManagedObjectContext, registry: FloatingNotesRegistry) {
        let engine = SyncEngine(context: context, registry: registry)
        shared = engine
        engine.start()
    }

    // MARK: - 开关

    func start() {
        guard SyncConfig.isEnabled, phase == .off || isFailed else { return }
        needsPermission = false
        phase = .starting
        generation += 1
        let gen = generation
        let root = SyncConfig.folder
        let stateDirectory = PerchPaths.syncStateDirectory
        io.async {
            let identity = SyncDeviceIdentity.loadOrCreate(in: stateDirectory)
            let state = SyncLocalState(directory: stateDirectory)
            state.load()
            let folder = SyncFolder(root: root)
            let prepared = Result { try folder.prepare(device: identity.deviceID) }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if case .failure(let error) = prepared {
                    self.fail(error.localizedDescription,
                              needsPermission: (error as? SyncFolder.PrepareError)?.isPermission ?? false)
                    return
                }
                self.begin(folder: folder, identity: identity, state: state)
            }
        }
    }

    func stop() {
        generation += 1
        flushState()
        observers.forEach(NotificationCenter.default.removeObserver)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers.removeAll()
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
        timer = nil
        exportWork?.cancel()
        importWork?.cancel()
        importInFlight = false
        folder = nil
        state = nil
        identity = nil
        ownDeviceID = nil
        phase = .off
    }

    /// 退出前:把还在等待合并的修改导出,并等后台写完(最多几百毫秒)。
    func flushBeforeQuit() {
        guard state != nil else { return }
        exportWork?.cancel()
        exportPending()
        io.sync {}
    }

    /// 设置页改了开关或文件夹后调。
    func restart() {
        stop()
        start()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String, needsPermission: Bool = false) {
        NSLog("Perch sync: %@", message)
        stop()
        phase = .failed(message)
        self.needsPermission = needsPermission
    }

    private func begin(folder: SyncFolder, identity: SyncDeviceIdentity, state: SyncLocalState) {
        self.folder = folder
        self.identity = identity
        self.state = state
        ownDeviceID = identity.deviceID
        clock = HybridLogicalClock(deviceID: identity.deviceID,
                                   millis: state.meta.clockMillis,
                                   counter: state.meta.clockCounter)
        NSLog("Perch sync: started, device %@, folder %@", identity.deviceID, folder.root.path)

        // 先导出再导入(方案第 7 节):本机已有、但和别的 Mac 不一样的内容先写出去,
        // 合并时才会变成冲突副本;反过来先导入,本机的内容会被直接盖掉。
        exportAll()
        writeDeviceInfoIfNeeded(force: true)

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
        ) { [weak self] note in self?.handleDidSave(note) })
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let watcher = SyncFolderWatcher(root: folder.root,
                                        ignoring: folder.deviceDirectory(identity.deviceID)) { [weak self] in
            self?.scheduleImport(after: 1.0, reason: "folder changed")
        }
        watcher.start()
        self.watcher = watcher
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.scheduleImport(after: 0)
        }
        phase = .idle
        scheduleImport(after: 0)
    }

    @objc private func didWake() {
        scheduleImport(after: 3)
    }

    // MARK: - 导出

    private func handleDidSave(_ notification: Notification) {
        guard let saved = notification.object as? NSManagedObjectContext,
              saved.persistentStoreCoordinator === context.persistentStoreCoordinator else { return }
        // objectID 可以跨线程读;对象本身留到主线程再从 viewContext 取。
        var changedIDs: [NSManagedObjectID] = []
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey] {
            for object in notification.userInfo?[key] as? Set<NSManagedObject> ?? [] {
                changedIDs.append(object.objectID)
            }
        }
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        let hadDeletion = !deleted.isEmpty
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != nil else { return }
            for objectID in changedIDs {
                guard let object = try? self.context.existingObject(with: objectID) else { continue }
                switch object {
                case let note as Note:       self.pendingIDs[.notes, default: []].insert(note.id)
                case let group as NoteGroup: self.pendingIDs[.groups, default: []].insert(group.id)
                case let image as NoteImage:
                    if let id = image.id { self.pendingIDs[.images, default: []].insert(id) }
                default: break
                }
            }
            if hadDeletion { self.pendingDeletionScan = true }
            self.scheduleExport()
        }
    }

    private func scheduleExport() {
        exportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.exportPending() }
        exportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func exportPending() {
        guard state != nil else { return }
        let ids = pendingIDs
        let deletionScan = pendingDeletionScan
        pendingIDs = [:]
        pendingDeletionScan = false
        for id in ids[.groups] ?? [] { if let g = fetch(NoteGroup.self, id) { export(g) } }
        for id in ids[.images] ?? [] { if let i = fetch(NoteImage.self, id) { export(i) } }
        for id in ids[.notes] ?? [] { if let n = fetch(Note.self, id) { export(n) } }
        if deletionScan { exportLocalDeletions() }
        writeDeviceInfoIfNeeded(force: false)
        flushState()
    }

    /// 全量导出:启动时跑一次,本机从没同步过的记录都会写出去。
    private func exportAll() {
        for group in fetchAll(NoteGroup.self) { export(group) }
        for image in fetchAll(NoteImage.self) { export(image) }
        for note in fetchAll(Note.self) { export(note) }
        exportLocalDeletions()
        flushState()
    }

    private func export(_ note: Note) {
        var values = SyncCoreDataAdapter.fields(of: note)
        // 笔记先到、它的分组还没到时,本地只能是未分组。这不是本机的修改,不能写出去 ——
        // 否则会把所有设备上的这条笔记都移出分组。分组到了以后 relinkNotes 会放回去。
        let key = SyncLocalState.Key(kind: .notes, id: note.id)
        if note.group == nil,
           let wanted = state?[key]?.base[SyncFieldName.groupID]?.value.uuidValue,
           fetch(NoteGroup.self, wanted) == nil {
            values[SyncFieldName.groupID] = .uuid(wanted)
        }
        exportRecord(.notes, id: note.id, values: values,
                     historical: SyncCoreDataAdapter.historicalDate(of: note))
    }

    private func export(_ group: NoteGroup) {
        exportRecord(.groups, id: group.id, values: SyncCoreDataAdapter.fields(of: group),
                     historical: SyncCoreDataAdapter.historicalDate(of: group))
    }

    private func export(_ image: NoteImage) {
        guard let id = image.id, let folder, let identity else { return }
        let isNew = state?[.init(kind: .images, id: id)] == nil
        exportRecord(.images, id: id, values: SyncCoreDataAdapter.fields(of: image),
                     historical: SyncCoreDataAdapter.historicalDate(of: image))
        // 图片数据写进本机自己的文件夹,只在第一次导出时写一次。从别的设备收到的图片
        // 不会走到这里(导入后本地值和 base 一样,不导出)。
        guard isNew, let data = image.data else { return }
        let url = folder.blobURL(device: identity.deviceID, id: id, fileExtension: image.fileExtension)
        io.async {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            do { try folder.write(data, to: url) } catch { NSLog("Perch sync: blob write failed: %@", "\(error)") }
        }
    }

    /// 拿本地值和上次合并结果比,不一样的字段才打新时间戳写出去。
    private func exportRecord(_ kind: SyncFolder.Kind, id: UUID,
                              values: [String: SyncValue], historical: Date) {
        guard let state, let identity else { return }
        let key = SyncLocalState.Key(kind: kind, id: id)
        let current = state[key] ?? SyncRecordState()
        // base 里没有的字段当成 null:导入的记录里没出现过的字段(比如从没设过提醒)
        // 本地也是 null,不算本机改过。
        let changed = values.filter { name, value in (current.base[name]?.value ?? .null) != value }
        guard !changed.isEmpty else { return }

        let hlc: HLCTimestamp
        if current.base.isEmpty && current.own == nil {
            // 从没同步过:用记录自己的时间,不用当前时间(方案第 3 节)。
            hlc = HLCTimestamp(millis: Int64((historical.timeIntervalSince1970 * 1000).rounded(.down)),
                               counter: 0, deviceID: identity.deviceID)
            clock.observe(hlc)
        } else {
            hlc = clock.tick()
        }
        state.update(key) { s in
            var own = s.own ?? SyncRecord(id: id)
            for (name, value) in changed {
                let field = SyncField(value: value, hlc: hlc)
                own.fields[name] = field
                s.base[name] = field
            }
            // 版本向量只跟着正文走:只改了颜色之类的属性时不动它,否则本机文件里会出现
            // 「旧正文 + 新版本向量」,和别的设备一比就成了冲突。
            if kind == .notes, changed[SyncFieldName.content] != nil {
                s.baseVersion = s.baseVersion.incremented(for: identity.deviceID)
                own.contentVersion = s.baseVersion
            }
            s.own = own
            s.isDeleted = false
        }
        writeOwnRecord(key)
    }

    /// 本地没有了、但同步状态里还是活的记录 → 本机删掉的,写删除标记。
    /// 只处理在本机真正存在过的记录(`base` 不空):图片的数据还没下载下来、所以本地
    /// 没建出来的,不能当成删除 —— 否则会把它在所有设备上删掉。
    private func exportLocalDeletions() {
        guard let state, let folder, let identity else { return }
        let local: [SyncFolder.Kind: Set<UUID>] = [
            .notes: Set(fetchAll(Note.self).map(\.id)),
            .groups: Set(fetchAll(NoteGroup.self).map(\.id)),
            .images: Set(fetchAll(NoteImage.self).compactMap(\.id)),
        ]
        for kind in SyncFolder.Kind.allCases {
            for key in state.keys(of: kind) where !(local[kind]?.contains(key.id) ?? false) {
                guard let s = state[key], !s.isDeleted, !s.base.isEmpty else { continue }
                let blobExtension = s.base[SyncFieldName.fileExtension]?.value.stringValue
                let hlc = clock.tick()
                state.update(key) { s in
                    var own = s.own ?? SyncRecord(id: key.id)
                    own.deleted = hlc
                    own.fields = [:]
                    s.own = own
                    s.base = [:]
                    s.isDeleted = true
                }
                writeOwnRecord(key)
                if kind == .images, let blobExtension {
                    let url = folder.blobURL(device: identity.deviceID, id: key.id,
                                             fileExtension: blobExtension)
                    io.async { folder.remove(url) }
                }
            }
        }
    }

    private func writeOwnRecord(_ key: SyncLocalState.Key) {
        guard let folder, let identity, let own = state?[key]?.own,
              let data = try? SyncRecord.makeEncoder().encode(own) else { return }
        let url = folder.recordURL(device: identity.deviceID, kind: key.kind, id: key.id)
        io.async {
            do { try folder.write(data, to: url) } catch { NSLog("Perch sync: write failed %@: %@", url.path, "\(error)") }
        }
    }

    private func removeOwnRecordFile(_ key: SyncLocalState.Key) {
        guard let folder, let identity else { return }
        let url = folder.recordURL(device: identity.deviceID, kind: key.kind, id: key.id)
        io.async { folder.remove(url) }
    }

    private func writeDeviceInfoIfNeeded(force: Bool) {
        guard let folder, let identity else { return }
        if !force, let last = lastDeviceInfoWrite, Date().timeIntervalSince(last) < 600 { return }
        lastDeviceInfoWrite = Date()
        let info = SyncFolder.DeviceInfo(
            deviceID: identity.deviceID,
            name: SyncDeviceIdentity.deviceName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            lastSeen: Date())
        guard let data = try? SyncFolder.makeEncoder().encode(info) else { return }
        io.async { try? folder.write(data, to: folder.deviceInfoURL(identity.deviceID)) }
    }

    /// 把同步状态和时钟写盘(后台队列)。
    private func flushState() {
        guard let state else { return }
        if state.meta.clockMillis != clock.millis || state.meta.clockCounter != clock.counter {
            state.meta.clockMillis = clock.millis
            state.meta.clockCounter = clock.counter
            state.markMetaDirty()
        }
        if let write = state.takePendingWrites() { io.async(execute: write) }
    }

    // MARK: - 导入

    func syncNow() { scheduleImport(after: 0) }

    private func scheduleImport(after delay: TimeInterval, reason: String = "") {
        guard state != nil else { return }
        if !reason.isEmpty { NSLog("Perch sync: import requested (%@)", reason) }
        importWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runImport() }
        importWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private struct DecodedFile {
        let file: SyncFolder.RemoteFile
        let record: SyncRecord
        /// 图片记录:数据本身(`blobs/` 里的文件)。
        let blob: Data?
    }

    private func runImport() {
        guard let state, let folder, let identity else { return }
        if importInFlight {
            importRequestedAgain = true
            return
        }
        importInFlight = true
        phase = .syncing
        let gen = generation
        let knownStats = state.meta.remoteStats
        let me = identity.deviceID

        io.async {
            folder.mergeDuplicateRoots()
            let files = folder.scanRemoteFiles(excluding: me)
            let present = Set(files.map(\.relativePath))
            let changed = files.filter { knownStats[$0.relativePath] != $0.stat }
            let removed = knownStats.keys.filter { !present.contains($0) }
            let datas = folder.readAll(changed.map(\.url))

            var decoded: [DecodedFile] = []
            var newerFormat: Int?
            for file in changed {
                guard let data = datas[file.url],
                      let record = try? JSONDecoder().decode(SyncRecord.self, from: data),
                      record.id == file.id else { continue }   // 还没下载完 / 坏文件:下次再试
                guard record.format <= SyncFormat.current else {
                    newerFormat = max(newerFormat ?? 0, record.format)
                    continue
                }
                var blob: Data?
                if file.kind == .images, record.deleted == nil,
                   let ext = record.fields[SyncFieldName.fileExtension]?.value.stringValue {
                    blob = folder.findBlob(id: file.id, fileExtension: ext, preferred: file.device)
                        .flatMap { try? Data(contentsOf: $0) }
                }
                decoded.append(DecodedFile(file: file, record: record, blob: blob))
            }
            let infos = folder.readDeviceInfos()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let newerFormat {
                    self.fail(SyncFolder.PrepareError.newerFormat(newerFormat).localizedDescription)
                    return
                }
                self.applyImport(decoded: decoded, removed: removed, deviceInfos: infos)
            }
        }
    }

    private func applyImport(decoded: [DecodedFile], removed: [String],
                             deviceInfos: [String: SyncFolder.DeviceInfo]) {
        guard let state, let identity else { return }
        devices = deviceInfos.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !decoded.isEmpty || !removed.isEmpty {
            NSLog("Perch sync: import — %d changed file(s), %d removed", decoded.count, removed.count)
        }

        var affected = Set<SyncLocalState.Key>()
        var blobs: [UUID: Data] = [:]
        var statsToRecord: [String: SyncFolder.FileStat] = [:]
        for item in decoded {
            let key = SyncLocalState.Key(kind: item.file.kind, id: item.file.id)
            state.update(key) { $0.remote[item.file.device] = item.record }
            affected.insert(key)
            if let blob = item.blob { blobs[item.file.id] = blob }
            // 图片的数据还没到的,先不记文件状态,下次再读一遍这条记录。
            let blobMissing = item.file.kind == .images && item.record.deleted == nil && item.blob == nil
            if !blobMissing { statsToRecord[item.file.relativePath] = item.file.stat }
            for field in item.record.fields.values { clock.observe(field.hlc) }
            if let deleted = item.record.deleted { clock.observe(deleted) }
        }
        for path in removed {
            // <设备>/<kind>/<UUID>.json
            let parts = path.split(separator: "/")
            guard parts.count == 3, let kind = SyncFolder.Kind(rawValue: String(parts[1])),
                  let id = UUID(uuidString: String(parts[2].dropLast(5))) else { continue }
            let key = SyncLocalState.Key(kind: kind, id: id)
            state.update(key) { $0.remote[String(parts[0])] = nil }
            affected.insert(key)
            state.meta.remoteStats[path] = nil
        }
        for (path, stat) in statsToRecord { state.meta.remoteStats[path] = stat }
        state.markMetaDirty()

        let names = deviceInfos.mapValues(\.name)
        var merged: [SyncLocalState.Key: MergedRecord] = [:]
        for key in affected {
            let versions = state[key]?.versions(ownDevice: identity.deviceID) ?? []
            guard !versions.isEmpty else { continue }
            if key.kind == .notes {
                let conflictContext = ConflictContext(deviceNames: names) { [weak state] id in
                    let s = state?[.init(kind: .notes, id: id)]
                    return s?.isDeleted == true || s?.hasDeletionMarker == true
                }
                merged[key] = SyncMerge.mergeNote(versions, context: conflictContext)
            } else {
                merged[key] = SyncMerge.mergeRecord(versions)
            }
        }

        // 要进回收站 / 归档 / 被删掉的笔记,本机开着浮窗的先关掉,字段下一拍再写
        // (见 FloatingNotesRegistry.closeWindowForSync)。
        for (key, result) in merged where key.kind == .notes {
            guard let note = fetch(Note.self, key.id) else { continue }
            let leaving = result.isDeleted
                || result.value(SyncFieldName.isTrashed) == .bool(true)
                || result.value(SyncFieldName.isArchived) == .bool(true)
            if leaving { registry?.closeWindowForSync(note: note) }
        }
        let gen = generation
        DispatchQueue.main.async {
            guard gen == self.generation else { return }
            self.apply(merged, blobs: blobs)
        }
    }

    private func apply(_ merged: [SyncLocalState.Key: MergedRecord], blobs: [UUID: Data]) {
        guard let state else { return }
        let order: [SyncFolder.Kind] = [.groups, .images, .notes]
        let groupsBefore = Set(fetchAll(NoteGroup.self).map(\.id))
        for kind in order {
            for (key, result) in merged where key.kind == kind {
                let applied: Bool
                switch kind {
                case .groups: applied = applyGroup(result)
                case .images: applied = applyImage(result, blob: blobs[key.id])
                case .notes:  applied = applyNote(result)
                }
                guard applied else { continue }
                let dropOwn = result.isDeleted && state[key]?.own != nil && state[key]?.own?.deleted == nil
                state.update(key) { s in
                    s.base = result.fields
                    s.baseVersion = result.contentVersion
                    s.isDeleted = result.isDeleted
                    // 别的设备删掉了:本机自己那份文件没用了,删掉省空间(删除标记在删除方那里)。
                    if dropOwn { s.own = nil }
                }
                if dropOwn { removeOwnRecordFile(key) }
                if key.kind == .notes { createConflictCopies(result.conflictCopies) }
            }
        }
        relinkNotes(toNewGroups: Set(fetchAll(NoteGroup.self).map(\.id)).subtracting(groupsBefore))
        if context.hasChanges {
            do { try context.save() } catch { NSLog("Perch sync: save failed: %@", "\(error)") }
        }
        flushState()
        lastSyncAt = Date()
        phase = .idle
        importInFlight = false
        if importRequestedAgain {
            importRequestedAgain = false
            scheduleImport(after: 0.5)
        }
    }

    /// 新到的分组:之前先到、按合并结果属于这些分组的笔记,现在放回去。
    private func relinkNotes(toNewGroups groupIDs: Set<UUID>) {
        guard let state, !groupIDs.isEmpty else { return }
        for key in state.keys(of: .notes) {
            guard let wanted = state[key]?.base[SyncFieldName.groupID]?.value.uuidValue,
                  groupIDs.contains(wanted),
                  let note = fetch(Note.self, key.id), note.group == nil else { continue }
            note.group = fetch(NoteGroup.self, wanted)
        }
    }

    private func applyGroup(_ result: MergedRecord) -> Bool {
        let existing = fetch(NoteGroup.self, result.id)
        if result.isDeleted {
            if let existing { context.delete(existing) }   // 组内笔记变成未分组(nullify)
            return true
        }
        let group = existing ?? {
            let g = NoteGroup(context: context)
            g.id = result.id
            g.name = ""
            g.createdAt = Date()
            return g
        }()
        SyncCoreDataAdapter.apply(result.fields.mapValues(\.value), to: group)
        return true
    }

    private func applyImage(_ result: MergedRecord, blob: Data?) -> Bool {
        let existing = fetch(NoteImage.self, result.id)
        if result.isDeleted {
            if let existing {
                // 本机文件夹里如果也存了一份数据(用 CloudKit 同步过的图片两边都有),一起删掉。
                if let folder, let identity {
                    let url = folder.blobURL(device: identity.deviceID, id: result.id,
                                             fileExtension: existing.fileExtension)
                    io.async { folder.remove(url) }
                }
                context.delete(existing)
            }
            return true
        }
        if let existing {
            SyncCoreDataAdapter.apply(result.fields.mapValues(\.value), to: existing)
            return true
        }
        // 数据还没下载下来就先不建,也不记 base(下次导入再试,删除检测也不会误判)。
        guard let blob else { return false }
        let image = NoteImage(context: context)
        image.id = result.id
        image.data = blob
        SyncCoreDataAdapter.apply(result.fields.mapValues(\.value), to: image)
        return true
    }

    private func applyNote(_ result: MergedRecord) -> Bool {
        let existing = fetch(Note.self, result.id)
        if result.isDeleted {
            guard let note = existing else { return true }
            ReminderScheduler.shared.cancel(noteID: note.id)
            NoteDisplayStore.clear(noteID: note.id)
            context.delete(note)
            return true
        }
        let note = existing ?? {
            let n = Note(context: context)
            n.id = result.id
            n.content = ""
            n.createdAt = Date()
            n.updatedAt = Date()
            return n
        }()
        let oldReminder = note.reminderDate
        let wasActive = !note.isTrashed && !note.isArchived
        SyncCoreDataAdapter.apply(result.fields.mapValues(\.value), to: note) { [weak self] id in
            self?.fetch(NoteGroup.self, id)
        }
        let isActive = !note.isTrashed && !note.isArchived
        if wasActive && !isActive { note.isPinned = false }
        if note.reminderDate != oldReminder || wasActive != isActive {
            rescheduleReminder(for: note, active: isActive)
        }
        return true
    }

    private func rescheduleReminder(for note: Note, active: Bool) {
        guard active, let date = note.reminderDate else {
            ReminderScheduler.shared.cancel(noteID: note.id)
            return
        }
        let body = note.content.components(separatedBy: .newlines)
            .dropFirst()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        ReminderScheduler.shared.schedule(noteID: note.id,
                                          title: note.cleanTitle.isEmpty ? L.t(.appName) : note.cleanTitle,
                                          body: String(body.prefix(120)), fireAt: date)
    }

    // MARK: - 冲突副本

    private func createConflictCopies(_ copies: [ConflictCopy]) {
        guard let state else { return }
        for copy in copies {
            let key = SyncLocalState.Key(kind: .notes, id: copy.id)
            // 已经有了(生成过,用户可能已经改过)或删过的,不再生成。
            guard state[key] == nil, fetch(Note.self, copy.id) == nil else { continue }
            ensureConflictGroup()
            let record = copy.makeRecord()
            let note = Note(context: context)
            note.id = copy.id
            note.content = ""
            note.createdAt = copy.hlc.date
            note.updatedAt = copy.hlc.date
            SyncCoreDataAdapter.apply(record.fields.mapValues(\.value), to: note) { [weak self] id in
                self?.fetch(NoteGroup.self, id)
            }
            state.update(key) { s in
                s.own = record
                s.base = record.fields
                s.baseVersion = record.contentVersion ?? VersionVector()
            }
            writeOwnRecord(key)
            conflictCopiesCreated += 1
            NSLog("Perch sync: conflict on note %@, kept the other version as %@",
                  copy.originalID.uuidString, copy.id.uuidString)
        }
    }

    /// 「同步冲突」分组:UUID、名字、时间戳都是固定的,每台 Mac 建出来的完全一样;
    /// 用户改了名字或排序,时间戳更新就以用户的为准。用户删掉了就不再建,副本落到未分组。
    private func ensureConflictGroup() {
        guard let state else { return }
        let id = DeterministicUUID.conflictGroupID
        let key = SyncLocalState.Key(kind: .groups, id: id)
        guard fetch(NoteGroup.self, id) == nil, state[key]?.isDeleted != true,
              state[key]?.hasDeletionMarker != true else { return }
        let fixed = HLCTimestamp(millis: 0, counter: 0, deviceID: "perch")
        let values: [String: SyncValue] = [
            SyncFieldName.name: .string("同步冲突 / Sync conflicts"),
            SyncFieldName.createdAt: .date(Date(timeIntervalSince1970: 0)),
            SyncFieldName.sortOrder: .int(1_000_000),
        ]
        let record = SyncRecord(id: id, fields: values.mapValues { SyncField(value: $0, hlc: fixed) })
        let group = NoteGroup(context: context)
        group.id = id
        group.name = ""
        group.createdAt = Date()
        SyncCoreDataAdapter.apply(values, to: group)
        state.update(key) { s in
            s.own = record
            s.base = record.fields
        }
        writeOwnRecord(key)
    }

    // MARK: - Core Data

    private func fetch<T: NSManagedObject>(_ type: T.Type, _ id: UUID) -> T? {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func fetchAll<T: NSManagedObject>(_ type: T.Type) -> [T] {
        (try? context.fetch(NSFetchRequest<T>(entityName: String(describing: type)))) ?? []
    }
}

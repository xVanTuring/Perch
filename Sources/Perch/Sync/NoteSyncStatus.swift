import Foundation

/// 一条便签的同步进度:本机的修改有没有发出去。浮窗标题条(提醒铃铛左边)和管理窗口
/// 工具栏显示它,由 `SyncEngine` 更新,只在主线程读写。
///
/// 只看本机要发出去的东西:便签自己的记录文件,加上正文里引用的、本机写出的图片。
/// 从别的 Mac 收到的内容本机不用再发,收到就算同步好了。
final class NoteSyncStatus: ObservableObject {
    enum State: Equatable {
        /// 刚改过,还没写进同步文件夹(保存后等 2 秒,把连续的修改合成一次)。
        case pending
        /// 已写进 iCloud 云盘里的同步文件夹,iCloud 云盘还没上传完。
        case uploading
        case synced
        case failed(String)
    }

    let noteID: UUID
    /// nil = 同步没开或还在启动,不显示。
    @Published private(set) var state: State?
    /// 本次运行中最后一次发出 / 收到这条便签的时间。之前的运行里同步过的是 nil。
    @Published private(set) var lastSyncedAt: Date?
    /// 同步文件夹在 iCloud 云盘里:说明文字讲「上传到 iCloud 云盘」,否则讲「写入同步文件夹」。
    @Published private(set) var usesICloudDrive = true
    /// 计算状态要读正文(找引用的图片)。界面持有便签,这里不延长它的生命。
    weak var note: Note?

    private init(note: Note) {
        noteID = note.id
        self.note = note
    }

    /// 界面拿状态对象都走这里:同一条便签共用一个,没有界面在用时自动释放。
    static func of(_ note: Note) -> NoteSyncStatus {
        let key = note.id as NSUUID
        if let existing = live.object(forKey: key) {
            existing.note = note
            return existing
        }
        let status = NoteSyncStatus(note: note)
        live.setObject(status, forKey: key)
        SyncEngine.shared?.refresh(status)
        return status
    }

    private static let live = NSMapTable<NSUUID, NoteSyncStatus>.strongToWeakObjects()

    /// 正被界面使用的状态对象。
    static var allLive: [NoteSyncStatus] {
        live.objectEnumerator()?.allObjects as? [NoteSyncStatus] ?? []
    }

    /// 值没变就不赋 —— `@Published` 每次赋值都会让界面重绘。
    func update(state: State?, lastSyncedAt: Date?, usesICloudDrive: Bool) {
        if self.state != state { self.state = state }
        if self.lastSyncedAt != lastSyncedAt { self.lastSyncedAt = lastSyncedAt }
        if self.usesICloudDrive != usesICloudDrive { self.usesICloudDrive = usesICloudDrive }
    }
}

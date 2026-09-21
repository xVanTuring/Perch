import AppKit
import Combine
import CoreData
import MarkdownEngine

/// 引擎取图的入口(`EmbeddedImageProvider`),两种来源:
/// - `![[名称|UUID]]`:按 UUID 到 `NoteImageStore` 找图片(粘贴 / 拖入时存进去的,
///   或者从其他设备同步下来的)。
/// - `![alt](https://…)`:引擎把 URL 放在 `name` 里,交给 `RemoteImageLoader`。
///
/// 图片是「后到」的两种情况:网络图片异步下载完成、同步来的图片记录晚于便签正文
/// 到达。这两种情况都让 `revision` 加一,编辑器通过 `@ObservedObject` 重新渲染,
/// 引擎发现 `fingerprint()` 变了就重新取图。
final class NoteImageProvider: ObservableObject, EmbeddedImageProvider, @unchecked Sendable {
    static let shared = NoteImageProvider(store: .shared, remote: .shared)

    @Published private(set) var revision = 0

    private let store: NoteImageStore
    private let remote: RemoteImageLoader
    private var mergeObserver: NSObjectProtocol?

    init(store: NoteImageStore, remote: RemoteImageLoader) {
        self.store = store
        self.remote = remote
        // CloudKit 导入在后台 context 里写入,合并进 viewContext 时会发这个通知。
        // 只关心有没有新的 NoteImage 记录:有的话,之前找不到图的便签现在可能找得到了。
        mergeObserver = NotificationCenter.default.addObserver(
            forName: NSManagedObjectContext.didMergeChangesObjectIDsNotification,
            object: store.context,
            queue: .main
        ) { [weak self] note in
            let inserted = note.userInfo?[NSInsertedObjectIDsKey] as? Set<NSManagedObjectID> ?? []
            guard inserted.contains(where: { $0.entity.name == "NoteImage" }) else { return }
            self?.revision &+= 1
        }
    }

    deinit {
        if let mergeObserver { NotificationCenter.default.removeObserver(mergeObserver) }
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        if let raw = reference.id, let id = UUID(uuidString: raw) {
            return store.image(for: id)
        }
        if let url = URL(string: reference.name),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return remote.image(for: url) { [weak self] in self?.revision &+= 1 }
        }
        return nil
    }

    func fingerprint() -> AnyHashable { revision }
}

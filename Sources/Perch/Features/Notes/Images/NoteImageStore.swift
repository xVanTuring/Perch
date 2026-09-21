import AppKit
import UniformTypeIdentifiers

/// 便签图片的本地存储。粘贴 / 拖入的图片会被复制进 App 自己的目录
/// (`~/Library/Application Support/Perch/Images/<UUID>.<扩展名>`),便签正文里
/// 只留 `![[名称|UUID]]`,不依赖原文件的路径 —— 原文件之后被移动或删除也不影响。
///
/// ⚠️ 目前只存在本机,这个目录不参与 iCloud 同步。换一台设备打开同一条便签时,
/// 找不到对应文件,编辑器里会退化为淡色的源码文本。
final class NoteImageStore: @unchecked Sendable {
    static let shared = NoteImageStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Perch/Images", isDirectory: true)
    }

    struct StoredImage {
        let id: UUID
        /// 写进 `![[名称|UUID]]` 的名称:原文件名,或粘贴时生成的名字。
        let displayName: String
    }

    enum ImportError: Error {
        case notAnImage
        case tooLarge
    }

    /// 单张图片上限。截图和照片一般在几 MB,再大的多半是误粘贴。
    static let maxBytes = 30 * 1024 * 1024

    private let directory: URL
    private let lock = NSLock()
    /// UUID → 文件。第一次查询时扫一遍目录建立,之后导入的图片随手登记。
    private var index: [UUID: URL]?
    private let decoded = NSCache<NSString, NSImage>()

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: 读取

    func image(for id: UUID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = decoded.object(forKey: key) { return cached }
        guard let url = fileURL(for: id), let image = NSImage(contentsOf: url) else { return nil }
        decoded.setObject(image, forKey: key)
        return image
    }

    func fileURL(for id: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if index == nil { index = Self.scan(directory) }
        return index?[id]
    }

    // MARK: 导入

    /// 复制一个图片文件进存储。不是图片、或超过上限时抛错。
    func importFile(_ source: URL) throws -> StoredImage {
        guard let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: .image) else { throw ImportError.notAnImage }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else { throw ImportError.tooLarge }

        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).\(source.pathExtension.lowercased())")
        try ensureDirectory()
        try FileManager.default.copyItem(at: source, to: destination)
        // 扩展名像图片不代表真能解码;解不出来就撤销这次复制。
        guard NSImage(contentsOf: destination) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.notAnImage
        }
        register(id, at: destination)
        return StoredImage(id: id, displayName: Self.sanitizedName(source.lastPathComponent))
    }

    /// 写入一段图片数据(截图、网页里「拷贝图片」)。
    func importImageData(_ data: Data, fileExtension: String = "png", name: String) throws -> StoredImage {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        guard NSImage(data: data) != nil else { throw ImportError.notAnImage }

        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        try ensureDirectory()
        try data.write(to: destination, options: .atomic)
        register(id, at: destination)
        return StoredImage(id: id, displayName: Self.sanitizedName(name))
    }

    // MARK: 内部

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func register(_ id: UUID, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        if index == nil { index = Self.scan(directory) }
        index?[id] = url
    }

    private static func scan(_ directory: URL) -> [UUID: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var map: [UUID: URL] = [:]
        for file in files {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
                map[id] = file
            }
        }
        return map
    }

    /// 名称会写进 `![[名称|UUID]]`,其中的 `|` `[` `]` 和换行都会破坏语法,替换成 `-`。
    static func sanitizedName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "|[]").union(.newlines)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "image" : cleaned
    }
}

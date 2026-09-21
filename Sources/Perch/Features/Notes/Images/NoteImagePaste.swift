import AppKit
import MarkdownEngine
import UniformTypeIdentifiers

/// 粘贴板里的图片 → 便签正文里的 `![[名称|UUID]]`。
///
/// 给引擎的 `onPasteImage` 用:返回要插入的文本;返回 nil 表示「这次粘贴不是图片」,
/// 引擎会继续按文本粘贴。粘贴的每一次都会先问到这里,所以判断要便宜、要保守。
///
/// `ownerNoteID` 是正在编辑的便签 id,记在图片上,便签被永久删除时用来清理图片。
enum NoteImagePaste {
    private static let bitmapTypes: [NSPasteboard.PasteboardType] =
        [UTType.png, .tiff, .jpeg, .heic, .gif].map { NSPasteboard.PasteboardType($0.identifier) }

    static func embed(
        from pasteboard: NSPasteboard, ownerNoteID: UUID?, store: NoteImageStore = .shared
    ) -> String? {
        // 复制的是文件(Finder):只处理图片文件;别的文件(如 .md)交回引擎按文本处理。
        // 这一步必须在位图判断之前,Finder 复制文件时还会带上文件名文本。
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            return embeds(forFileURLs: fileURLs, ownerNoteID: ownerNoteID, store: store)
        }

        // 位图:截图、预览里的复制、网页里「拷贝图片」。只认真正的位图格式,
        // 不去扫 PDF 之类的类型 —— 从 Pages 等处复制文字也会带 PDF,不能当成图片。
        guard pasteboard.availableType(from: bitmapTypes) != nil else { return nil }

        // 同时带着真正的文本(比如 Excel 复制单元格既有文本又有图片)时文本优先;
        // 只有一个网址不算文本 —— 浏览器「拷贝图片」常会附带图片地址。
        // 也让应用自己复制的 `![[…]]` 文本原样往返,不会被换成图片。
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, !isSingleWebURL(text) {
            return nil
        }

        guard let png = PasteboardImageReader.imageData(from: pasteboard) else { return nil }
        do {
            let stored = try store.importImageData(
                png, fileExtension: "png", name: pastedName(), ownerNoteID: ownerNoteID
            )
            return markdown(for: stored)
        } catch {
            NSLog("Perch image paste failed: \(error)")
            NSSound.beep()
            return nil
        }
    }

    /// 把若干文件存进图片库,返回要插入的文本(多张之间空一行);没有图片文件时返回 nil。
    /// 拖入文件也走这里。
    static func embeds(
        forFileURLs urls: [URL], ownerNoteID: UUID?, store: NoteImageStore = .shared
    ) -> String? {
        let imageFiles = urls.filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }
        guard !imageFiles.isEmpty else { return nil }

        var result: [String] = []
        for url in imageFiles {
            do {
                result.append(markdown(for: try store.importFile(url, ownerNoteID: ownerNoteID)))
            } catch {
                NSLog("Perch image import failed (\(url.lastPathComponent)): \(error)")
                NSSound.beep()
            }
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }

    private static func markdown(for stored: NoteImageStore.StoredImage) -> String {
        ImageEmbedReference(name: stored.displayName, nodeID: stored.id).markdown
    }

    private static func pastedName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(formatter.string(from: Date())).png"
    }

    private static func isSingleWebURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

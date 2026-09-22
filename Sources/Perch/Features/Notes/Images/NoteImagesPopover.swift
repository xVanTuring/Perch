import AppKit
import SwiftUI

/// 便签的图片面板:一行一张,列出这条便签关联到的所有图片。
///
/// 存在的理由是**引用和图片是两回事**。图片存在 Core Data 的 `NoteImage` 里,
/// 正文里只有 `![[名称|UUID]]` 这一行引用;引用删掉、改坏、被 undo 吃掉,图片
/// 本身都还在库里(清理只发生在便签被永久删除时,见 FloatingNotesRegistry)。
/// 在这之前,除了翻 sqlite 没有任何办法把它找回来 —— 这个面板就是那个办法。
///
/// 「放回正文」把引用追加到便签末尾单独一行。不插在光标处:面板是从工具栏弹出来
/// 的,编辑器早就失焦了,光标位置对用户来说已经不是他看得见的那个位置。
struct NoteImagesPopover: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared
    /// 放回引用之后要刷新列表(那一行的状态从「未引用」变成「已在正文中」)。
    @State private var images: [NoteImageStore.LinkedImage] = []

    private let store: NoteImageStore = .shared

    /// 这条便签有没有关联的图片 —— 调用方据此决定要不要显示入口按钮。
    /// 正文里有引用就直接算有(纯文本判断,不查库);一条引用都没有时才去库里
    /// 问一次有没有登记在它名下的孤儿图片 —— 正是这种情况下面板才真正有用。
    static func hasImages(_ note: Note) -> Bool {
        guard !note.isDeleted, note.managedObjectContext != nil else { return false }
        if note.content.contains("![[") { return true }
        return !NoteImageStore.shared.linkedImages(for: note).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.t(.noteImagesTitle))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if images.isEmpty {
                Text(L.t(.noteImagesEmpty))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(images) { image in
                            NoteImageRow(image: image, store: store) { insert(image) }
                            if image.id != images.last?.id {
                                Divider().padding(.leading, NoteImageRow.thumbnailSide + 26)
                            }
                        }
                    }
                }
                // **必须是确定高度,不能只给 maxHeight**:ScrollView 没有固有高度,
                // popover 按内容的理想尺寸自适应,于是 maxHeight 下它收缩成一条
                // (只露出第一行的一角)。这里按行数把高度算出来,超过 5 行才滚动。
                .frame(height: listHeight)
            }
        }
        .frame(width: 460)
        .onAppear(perform: reload)
    }

    /// 列表区高度:行数 × 行高(行之间还有 1pt 分隔线),最多 5 行,再多就滚动。
    private var listHeight: CGFloat {
        let rows = CGFloat(min(images.count, 5))
        return rows * NoteImageRow.rowHeight + max(0, rows - 1)
    }

    private func reload() {
        guard !note.isDeleted, note.managedObjectContext != nil else {
            images = []
            return
        }
        images = store.linkedImages(for: note)
    }

    /// 把引用追加到正文末尾单独一行。图片本体一直都在,这里只补那一行文字。
    /// 正文里已经有这张图也照插 —— 同一张图用两次是正常需求,面板没理由拦着。
    private func insert(_ image: NoteImageStore.LinkedImage) {
        guard !note.isDeleted, note.managedObjectContext != nil else { return }
        let name = NoteImageStore.defaultName(for: image.createdAt, fileExtension: image.fileExtension)
        let reference = NoteImagePaste.markdown(name: name, id: image.id)
        var content = note.content
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        note.content = content + reference
        note.updatedAt = Date()
        try? note.managedObjectContext?.save()
        reload()
    }
}

/// 一行:缩略图 + 名称 + 导入时间 / 尺寸,右边是「插入」按钮。
/// 已经在正文里的那些在按钮左边多一个 ✓,那只是状态标记,不挡插入。
private struct NoteImageRow: View {
    /// 缩略图边长。截图大多是宽幅的,小方块里缩到看不出是什么就失去了挑选的
    /// 意义 —— 这个面板的用处正是「认出是哪张图」,所以给得比常见的列表图标大。
    static let thumbnailSide: CGFloat = 72
    static let verticalPadding: CGFloat = 8
    /// 行高由缩略图决定(文字那一列比它矮)。外面按行数算 popover 高度要用。
    static let rowHeight: CGFloat = thumbnailSide + verticalPadding * 2

    let image: NoteImageStore.LinkedImage
    let store: NoteImageStore
    let onInsert: () -> Void

    /// 解码走 `store.image(for:)`,它内部有 NSCache —— 正文里已经渲染过的图
    /// 在这里是缓存命中,不会再解一遍。
    private var thumbnail: NSImage? { store.image(for: image.id) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(NoteImageStore.defaultName(for: image.createdAt, fileExtension: image.fileExtension))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if image.isReferenced {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .help(L.t(.noteImagesInNote))
            }
            Button(L.t(.noteImagesInsert), action: onInsert)
                .controlSize(.small)
                .help(L.t(.noteImagesInsertHelp))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Self.verticalPadding)
        .frame(height: Self.rowHeight)
    }

    private var subtitle: String {
        let when = DateFormatter.localizedString(
            from: image.createdAt, dateStyle: .short, timeStyle: .short
        )
        guard let size = thumbnail?.size, size.width > 0 else { return when }
        return "\(when) · \(Int(size.width))×\(Int(size.height))"
    }
}

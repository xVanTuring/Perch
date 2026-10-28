import SwiftUI
import CoreData

/// 同步冲突:冲突副本和原便签并排对比,选一个留下(docs/icloud-drive-sync.md 第 11 节第二阶段)。
/// 两种选择都把冲突副本移进回收站(可以恢复),不直接删除。
struct ConflictCompareView: View {
    @ObservedObject var copy: Note
    let originalID: UUID
    let floating: FloatingNotesRegistry
    @Environment(\.dismiss) private var dismiss

    private var original: Note? {
        guard let context = copy.managedObjectContext else { return nil }
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "id == %@", originalID as NSUUID)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    var body: some View {
        let parts = ConflictHeader.split(copy.content)
        let otherLines = parts.body.components(separatedBy: "\n")
        let current = original
        let currentLines = current?.content.components(separatedBy: "\n") ?? []
        // 逐行比较:另一版里多出来的行、现在的便签里多出来的行,各自高亮。
        var otherMarks = Set<Int>()
        var currentMarks = Set<Int>()
        for change in otherLines.difference(from: currentLines) {
            switch change {
            case .insert(let offset, _, _): otherMarks.insert(offset)
            case .remove(let offset, _, _): currentMarks.insert(offset)
            }
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text(L.t(.syncConflictTitle)).font(.headline)
            Text(L.t(.syncConflictExplain))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                pane(title: L.t(.syncConflictOther), subtitle: parts.header,
                     lines: otherLines, marks: otherMarks, tint: .green)
                if current != nil {
                    pane(title: L.t(.syncConflictCurrent), subtitle: nil,
                         lines: currentLines, marks: currentMarks, tint: .orange)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t(.syncConflictCurrent)).font(.subheadline.weight(.medium))
                        Text(L.t(.syncConflictOriginalGone))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            Text(L.t(.syncConflictFooter))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(L.t(.cancel), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let current {
                    Button(L.t(.syncConflictKeepCurrent)) { keepCurrent() }
                    Button(L.t(.syncConflictUseOther)) { useOther(parts.body, in: current) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L.t(.syncConflictKeepAsNote)) { keepAsNote(parts.body) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 820, height: 560)
    }

    private func pane(title: String, subtitle: String?, lines: [String],
                      marks: Set<Int>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(marks.contains(index) ? tint.opacity(0.18) : Color.clear)
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 用另一版的内容替换原便签,冲突副本进回收站。
    private func useOther(_ text: String, in current: Note) {
        current.content = text
        current.updatedAt = Date()
        try? current.managedObjectContext?.save()
        floating.delete(note: copy)
        dismiss()
    }

    /// 保留原便签现在的内容,冲突副本进回收站。
    private func keepCurrent() {
        floating.delete(note: copy)
        dismiss()
    }

    /// 原便签已经不在了:把冲突副本变成普通便签(去掉说明行,移出「同步冲突」分组)。
    private func keepAsNote(_ text: String) {
        copy.content = text
        copy.group = nil
        copy.updatedAt = Date()
        try? copy.managedObjectContext?.save()
        dismiss()
    }
}

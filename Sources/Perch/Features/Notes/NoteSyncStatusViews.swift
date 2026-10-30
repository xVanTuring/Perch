import SwiftUI

// 便签的同步状态(NoteSyncStatus)在界面上的样子:浮窗标题条上提醒铃铛左边一个图标,
// 管理窗口工具栏上一个按钮。两处点开都是同一个说明弹窗(NoteSyncDetailView)。

extension NoteSyncStatus.State {
    var symbolName: String {
        switch self {
        case .pending:   return "arrow.triangle.2.circlepath.icloud"
        case .uploading: return "icloud.and.arrow.up"
        case .synced:    return "checkmark.icloud"
        case .failed:    return "exclamationmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .uploading: return .primary.opacity(0.65)
        case .synced:              return .green
        case .failed:              return .orange
        }
    }

    var isInProgress: Bool { self == .pending || self == .uploading }
}

extension NoteSyncStatus {
    /// 状态一句话。nil 状态(同步在启动)只在管理窗口工具栏出现。
    var title: String {
        switch state {
        case nil:          return L.t(.noteSyncStarting)
        case .pending:     return L.t(.noteSyncPending)
        case .uploading:   return L.t(.noteSyncUploading)
        case .synced:      return L.t(.noteSyncSynced)
        case .failed:      return L.t(.noteSyncFailed)
        }
    }

    var detail: String? {
        switch state {
        case nil:                  return nil
        case .pending:             return L.t(.noteSyncPendingDetail)
        case .uploading:           return L.t(.noteSyncUploadingDetail)
        case .synced:              return L.t(usesICloudDrive ? .noteSyncSyncedICloud : .noteSyncSyncedFolder)
        case .failed(let message): return message
        }
    }
}

/// 点开状态图标看到的说明:状态、原因、本次运行中最后一次同步的时间。
struct NoteSyncDetailView: View {
    @ObservedObject var status: NoteSyncStatus
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(status.title).font(.headline)
            } icon: {
                Image(systemName: status.state?.symbolName ?? "icloud")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.state?.tint ?? .secondary)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = status.lastSyncedAt {
                Text(L.t(.noteSyncLastSynced, Self.format(date)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 浮窗标题条上、提醒铃铛左边的同步状态。
///
/// - 改完、正在发出去(待同步 / 上传中):一直显示;
/// - 发完:显示几秒「已同步」再隐去;鼠标移进浮窗时随时能看到当前状态;
/// - 出错:一直显示。
/// - 同步没开:不画,也不占位。
struct StickySyncIndicator: View {
    @ObservedObject var status: NoteSyncStatus
    let hovering: Bool
    @State private var justFinished = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showDetail = false

    var body: some View {
        if let state = status.state {
            let visible = hovering || justFinished || state != .synced || showDetail
            Button {
                showDetail.toggle()
            } label: {
                Image(systemName: state.symbolName)
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state.tint)
                    .symbolEffect(.pulse, isActive: state.isInProgress)
                    .contentShape(Rectangle())
                    .frame(width: 20, height: 20)
                    // 和铃铛一样的毛玻璃圆底:长标题截尾时盖住压在下面的字。
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .help(status.title)
            .accessibilityLabel(status.title)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeOut(duration: 0.2), value: visible)
            .popover(isPresented: $showDetail, arrowEdge: .top) {
                NoteSyncDetailView(status: status)
            }
            .onChange(of: status.state) { old, new in
                hideTask?.cancel()
                guard new == .synced, old?.isInProgress == true else {
                    justFinished = false
                    return
                }
                justFinished = true
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    justFinished = false
                }
            }
        }
    }
}

/// 管理窗口工具栏上的同步状态:选中一条便签时显示它的状态,点开看说明。
struct NoteSyncToolbarButton: View {
    @ObservedObject var status: NoteSyncStatus
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail.toggle()
        } label: {
            Label {
                Text(status.title)
            } icon: {
                Image(systemName: status.state?.symbolName ?? "icloud")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.state?.tint ?? .secondary)
                    .symbolEffect(.pulse, isActive: status.state?.isInProgress == true)
            }
        }
        .help(status.title)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            NoteSyncDetailView(status: status)
        }
    }
}

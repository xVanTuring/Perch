import AppKit
import SwiftUI

/// Settings → 同步。打开 / 关闭同步、选同步文件夹、看状态和设备。
/// 开关和文件夹改了立即生效(SyncEngine.restart),不用重启 App。
struct SyncTab: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @AppStorage(SettingsKey.syncEnabled) private var enabled = false
    @AppStorage(SettingsKey.syncFolderPath) private var customFolderPath = ""

    var body: some View {
        if let engine = SyncEngine.shared {
            SyncTabContent(engine: engine, enabled: $enabled, customFolderPath: $customFolderPath)
        }
    }
}

private struct SyncTabContent: View {
    @ObservedObject var engine: SyncEngine
    @Binding var enabled: Bool
    @Binding var customFolderPath: String

    private var debugOverride: Bool { SyncConfig.debugFolderOverride != nil }
    private var isOn: Bool { enabled || debugOverride }

    var body: some View {
        Form {
            Section {
                Toggle(L.t(.syncEnable), isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        enabled = newValue
                        engine.restart()
                    }
                ))
                .disabled(debugOverride)
            } footer: {
                Text(L.t(.syncEnableDesc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent(L.t(.syncFolder)) {
                    Text((SyncConfig.folder.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    if debugOverride {
                        Text(L.t(.syncDebugOverride))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(L.t(.syncShowInFinder)) { showInFinder() }
                    if !customFolderPath.isEmpty {
                        Button(L.t(.syncFolderReset)) { setFolder(nil) }
                            .disabled(debugOverride)
                    }
                    Button(L.t(.syncFolderChange)) { chooseFolder() }
                        .disabled(debugOverride)
                }
            } footer: {
                Text(L.t(.syncFolderFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isOn {
                Section {
                    LabeledContent(L.t(.syncStatus)) {
                        Text(statusText)
                            .foregroundStyle(isFailed ? Color.red : Color.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent(L.t(.syncLastSync)) {
                        Text(engine.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .standard) }
                             ?? L.t(.syncNever))
                            .foregroundStyle(.secondary)
                    }
                    if engine.conflictCopiesCreated > 0 {
                        LabeledContent(L.t(.syncConflicts)) {
                            Text("\(engine.conflictCopiesCreated)")
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Spacer()
                        if isFailed {
                            if engine.needsPermission {
                                Button(L.t(.syncOpenPrivacySettings)) { openPrivacySettings() }
                            }
                            Button(L.t(.syncRetry)) { engine.restart() }
                        } else {
                            Button(L.t(.syncNow)) { engine.syncNow() }
                                .disabled(engine.phase != .idle)
                        }
                    }
                }

                if !engine.devices.isEmpty {
                    Section(L.t(.syncDevices)) {
                        ForEach(engine.devices, id: \.deviceID) { device in
                            let isThisMac = device.deviceID == engine.ownDeviceID
                            LabeledContent(isThisMac ? L.t(.syncThisMac, device.name) : device.name) {
                                HStack(spacing: 10) {
                                    Text(L.t(.syncLastSeen,
                                             device.lastSeen.formatted(.relative(presentation: .named))))
                                        .foregroundStyle(.secondary)
                                    if !isThisMac {
                                        Button(L.t(.syncRemoveDevice)) { confirmRemove(device) }
                                            .buttonStyle(.borderless)
                                            .disabled(engine.phase != .idle)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 760, height: isOn ? 560 : 340)
    }

    private var isFailed: Bool {
        if case .failed = engine.phase { return true }
        return false
    }

    private var statusText: String {
        switch engine.phase {
        case .off:                 return L.t(.syncStatusOff)
        case .starting:            return L.t(.syncStatusStarting)
        case .idle:                return L.t(.syncStatusIdle)
        case .syncing:             return L.t(.syncStatusSyncing)
        case .failed(let message): return L.t(.syncStatusFailed, message)
        }
    }

    private func confirmRemove(_ device: SyncFolder.DeviceInfo) {
        let alert = NSAlert()
        alert.messageText = L.t(.syncRemoveDeviceTitle, device.name)
        alert.informativeText = L.t(.syncRemoveDeviceMessage)
        alert.addButton(withTitle: L.t(.syncRemoveDeviceConfirm))
        alert.addButton(withTitle: L.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.removeDevice(device.deviceID)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInFinder() {
        let folder = SyncConfig.folder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(folder.deletingLastPathComponent())
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L.t(.syncChooseFolder)
        panel.directoryURL = SyncConfig.folder.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    private func setFolder(_ url: URL?) {
        customFolderPath = url?.path ?? ""
        // @AppStorage 写盘在本轮 runloop 末尾,SyncConfig 读的是 UserDefaults,先同步写进去。
        UserDefaults.standard.set(customFolderPath, forKey: SettingsKey.syncFolderPath)
        if isOn { engine.restart() }
    }
}

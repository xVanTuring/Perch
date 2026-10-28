import AppKit

/// iCloud 同步下线(`CloudKitConfig.syncAvailable = false`)后,升级上来的第一次启动
/// 弹一次说明。
///
/// 只对**开过同步**的 Mac 弹:旧开关 `SettingsKey.iCloudSyncEnabled` 还是 true。
/// 从没开过同步的用户、全新安装都不弹 —— 对他们什么都没变。弹之前先记
/// `SettingsKey.didShowICloudSunsetNotice`,之后不再弹(弹框期间崩了也不会反复弹)。
/// 旧开关 key 本身不动,CLAUDE.md "iCloud sync is off" 说明了为什么重开同步要换新 key。
enum ICloudSunsetNotice {
    static func showIfNeeded() {
        guard !CloudKitConfig.syncAvailable else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.iCloudSyncEnabled),
              !defaults.bool(forKey: SettingsKey.didShowICloudSunsetNotice) else { return }
        defaults.set(true, forKey: SettingsKey.didShowICloudSunsetNotice)

        let alert = NSAlert()
        alert.messageText = L.t(.iCloudSunsetTitle)
        alert.informativeText = L.t(.iCloudSunsetBody)
        alert.addButton(withTitle: L.t(.ok))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

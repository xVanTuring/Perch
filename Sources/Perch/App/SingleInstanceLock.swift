import AppKit
import Foundation

/// 单实例守卫。两个 Perch 进程同时打开同一个 Core Data sqlite 会损坏库
/// (WAL/-shm 不是为「多进程并发写」设计的),所以进程启动**最早期**就抢一把
/// 文件锁,抢不到直接退出,绝不 touch `PersistenceController`。
///
/// 为什么用 `flock` 而不是枚举 `NSRunningApplication`:
/// - 文件锁是内核级原子操作,挡得住「两个进程几乎同时启动」的竞态;
///   枚举有 TOCTOU 窗口(查的时候没有,建 store 时却撞上)。
/// - 持锁进程崩溃 / 被 kill 时内核**自动**释放,不留死锁,无需清理 stale 文件。
///
/// 抢到的 fd 存成 static 全程不关 —— close 即释放锁,所以锁随进程生命周期持有,
/// 退出时由内核回收。
enum SingleInstanceLock {
    /// 持锁的 fd。**绝不 close** —— close 即解锁。
    private static var lockFD: Int32 = -1

    /// 第二个实例启动失败前往这个 distributed notification 上喊一声,已在跑的
    /// 实例收到就把 Manager 窗口浮上来 —— 菜单栏 App 没有 Dock 图标,否则用户
    /// 「又点了一下」却毫无反应,会以为没启动成功。
    static let secondLaunchNotification =
        Notification.Name("tech.xvanturing.Perch.secondInstanceLaunched")

    /// 抢锁。成功(可以正常启动)返回 true;已有实例占着锁返回 false。
    ///
    /// 失败后短暂重试 ~2s:开发循环 `pkill … && relaunch` 里旧进程可能还在
    /// `applicationShouldTerminate` 收尾、锁没放,给它时间退出;真有活着的实例
    /// 一直占着锁时,重试也拿不到,2s 后照常放弃。
    static func acquire() -> Bool {
        guard let lockURL = lockFileURL() else { return true }  // 拿不到路径就不挡,宁可放过

        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }  // 锁文件开不了也不挡

        // LOCK_EX | LOCK_NB:非阻塞抢独占锁,拿不到立刻返回,重试节奏我们自己控制。
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFD = fd                 // 持锁成功,fd 留到进程结束
                return true
            }
            usleep(100_000)                 // 100ms
        } while Date() < deadline

        close(fd)                           // 抢不到,这个 fd 没用了
        return false
    }

    /// 通知已在运行的实例:有人又想启动一次,把窗口浮上来。
    static func notifyExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            secondLaunchNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// `~/Library/Application Support/Perch/instance.lock` —— 跟 sqlite 同目录。
    /// DEBUG 用 `PERCH_DATA_DIR` 换了数据目录时锁也跟过去,测试实例能和正常实例同时跑。
    private static func lockFileURL() -> URL? {
        let fm = FileManager.default
        if let dir = PerchPaths.overriddenDataDirectory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("instance.lock")
        }
        guard let appSup = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = appSup.appendingPathComponent("Perch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock")
    }
}

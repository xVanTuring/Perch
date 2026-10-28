// Perch iCloud Drive 同步方案的验证小程序(docs/icloud-drive-sync.md 第 10 节)。
// 用法见同目录 README.md。只读写一个测试文件夹(默认 iCloud 云盘/Perch-probe),
// 不碰 Perch 的数据。
//
// 编译:swiftc -O tools/sync-probe/probe.swift -o ~/perch-probe

import Foundation
import CoreServices

let defaultDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Perch-probe")

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let host: String = {
    let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    return name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
}()

func now() -> String { iso.string(from: Date()) }

func log(_ message: String) {
    print("[\(now())] \(message)")
    fflush(stdout)
}

// MARK: - 参数

var args = Array(CommandLine.arguments.dropFirst())
var dir = defaultDir
if let i = args.firstIndex(of: "--dir"), i + 1 < args.count {
    dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    args.removeSubrange(i...(i + 1))
}
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

func ensureDir(_ url: URL) {
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        log("无法创建文件夹 \(url.path): \(error)")
        exit(1)
    }
}

// MARK: - write:写一个带时间的小文件,另一台 Mac 看到后能算出延迟

func writeOne(seq: Int) {
    let folder = dir.appendingPathComponent("devices/\(host)")
    ensureDir(folder)
    let body: [String: Any] = ["host": host, "seq": seq, "writtenAt": now()]
    let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let target = folder.appendingPathComponent(String(format: "%06d.json", seq))
    // 和正式方案一样:先写到同步文件夹之外的临时文件,再整体替换
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
        log("写入 \(target.lastPathComponent)")
    } catch {
        log("写入失败 \(target.path): \(error)")
    }
}

// MARK: - status:每个文件是否只在云端、下载状态

func describe(_ url: URL) -> String {
    var st = stat()
    let dataless = lstat(url.path, &st) == 0 && (st.st_flags & 0x4000_0000) != 0   // SF_DATALESS
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isUbiquitousItemKey,
                                     .ubiquitousItemDownloadingStatusKey,
                                     .ubiquitousItemHasUnresolvedConflictsKey]
    let v = try? url.resourceValues(forKeys: keys)
    let status = v?.ubiquitousItemDownloadingStatus?.rawValue ?? "无"
    return "\(url.path.replacingOccurrences(of: dir.path + "/", with: ""))  "
        + "大小=\(v?.fileSize.map(String.init) ?? "?")  只在云端=\(dataless)  "
        + "iCloud项目=\(v?.isUbiquitousItem.map { String($0) } ?? "?")  下载状态=\(status)  "
        + "有冲突=\(v?.ubiquitousItemHasUnresolvedConflicts.map { String($0) } ?? "?")"
}

func allFiles() -> [URL] {
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    return (e?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
}

// MARK: - watch:FSEvents,另一台 Mac 的文件下载到本机时打印并算延迟

func handleEvent(_ path: String, _ flags: FSEventStreamEventFlags) {
    var names: [String] = []
    let table: [(Int, String)] = [
        (kFSEventStreamEventFlagItemCreated, "创建"), (kFSEventStreamEventFlagItemRemoved, "删除"),
        (kFSEventStreamEventFlagItemRenamed, "改名"), (kFSEventStreamEventFlagItemModified, "修改"),
        (kFSEventStreamEventFlagItemInodeMetaMod, "元数据"), (kFSEventStreamEventFlagItemXattrMod, "扩展属性"),
    ]
    for (bit, name) in table where Int(flags) & bit != 0 { names.append(name) }
    var line = "事件 [\(names.joined(separator: ","))] 0x\(String(flags, radix: 16)) \(path)"
    let url = URL(fileURLWithPath: path)
    if url.pathExtension == "json", !path.contains("/devices/\(host)/"),
       FileManager.default.fileExists(atPath: path) {
        let start = Date()
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let written = (obj["writtenAt"] as? String).flatMap(iso.date(from:)) {
            line += String(format: "  ← 来自 %@,延迟 %.1f 秒(读文件 %.0f ms)",
                           obj["host"] as? String ?? "?",
                           Date().timeIntervalSince(written),
                           Date().timeIntervalSince(start) * 1000)
        }
    }
    log(line)
}

func watch() {
    ensureDir(dir)
    log("监听 \(dir.path)(Ctrl-C 退出)")
    var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, _, count, paths, flags, _ in
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        for i in 0..<count where i < list.count { handleEvent(list[i], flags[i]) }
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                         | kFSEventStreamCreateFlagUseCFTypes
                                         | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                           [dir.path] as CFArray,
                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                           0.2, flags) else {
        log("FSEventStreamCreate 失败")
        exit(1)
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
    dispatchMain()
}

// MARK: - 命令

switch command {
case "write":
    ensureDir(dir)
    let every = rest.first(where: { Int($0) != nil }).flatMap(Int.init)
    if rest.contains("--every"), let every {
        var seq = Int(Date().timeIntervalSince1970) % 1_000_000
        log("每 \(every) 秒写一个文件(Ctrl-C 退出)")
        Timer.scheduledTimer(withTimeInterval: TimeInterval(every), repeats: true) { _ in
            seq += 1
            writeOne(seq: seq)
        }.fire()
        RunLoop.main.run()
    } else {
        writeOne(seq: Int(Date().timeIntervalSince1970) % 1_000_000)
    }

case "watch":
    watch()

case "status":
    let files = allFiles()
    log("\(dir.path) 下共 \(files.count) 个文件")
    files.forEach { print(describe($0)) }

case "read":
    guard let path = rest.first else { log("用法:read <文件>"); exit(2) }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    print("读之前:" + describe(url))
    let start = Date()
    do {
        let data = try Data(contentsOf: url)
        log(String(format: "读到 %d 字节,用时 %.0f ms", data.count, Date().timeIntervalSince(start) * 1000))
        print(String(decoding: data.prefix(200), as: UTF8.self))
    } catch {
        log("读取失败:\(error)")
    }
    print("读之后:" + describe(url))

case "evict":
    guard let path = rest.first else { log("用法:evict <文件>"); exit(2) }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do {
        try FileManager.default.evictUbiquitousItem(at: url)
        log("已请求移除本地副本")
    } catch {
        log("evictUbiquitousItem 失败:\(error)\n可以改用 Finder:右键文件 →「移除下载项」")
    }
    print(describe(url))

case "bulk":
    let n = rest.first.flatMap(Int.init) ?? 500
    let folder = dir.appendingPathComponent("devices/\(host)/bulk")
    ensureDir(folder)
    let start = Date()
    for i in 0..<n {
        let body = "{\"host\":\"\(host)\",\"i\":\(i),\"writtenAt\":\"\(now())\",\"pad\":\"\(String(repeating: "x", count: 400))\"}"
        try? Data(body.utf8).write(to: folder.appendingPathComponent(String(format: "%05d.json", i)))
    }
    log(String(format: "写了 %d 个文件,用时 %.2f 秒", n, Date().timeIntervalSince(start)))

case "scan":
    let start = Date()
    var count = 0, dataless = 0
    for url in allFiles() {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            count += 1
            if st.st_flags & 0x4000_0000 != 0 { dataless += 1 }
        }
    }
    log(String(format: "全量检查 %d 个文件(其中只在云端 %d 个),用时 %.0f ms",
               count, dataless, Date().timeIntervalSince(start) * 1000))

case "readall":
    // 把所有只在云端的文件并发读一遍(读会触发下载),看并发下载要多久。
    let parallel = rest.first.flatMap(Int.init) ?? 8
    let targets = allFiles().filter { url in
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & 0x4000_0000 != 0
    }
    log("只在云端的文件 \(targets.count) 个,并发 \(parallel) 个读取")
    let start = Date()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = parallel
    let lock = NSLock()
    var ok = 0, failed = 0
    for url in targets {
        queue.addOperation {
            let success = (try? Data(contentsOf: url)) != nil
            lock.lock(); if success { ok += 1 } else { failed += 1 }; lock.unlock()
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    log(String(format: "读完:成功 %d,失败 %d,用时 %.1f 秒", ok, failed, Date().timeIntervalSince(start)))

case "clean":
    do {
        try FileManager.default.removeItem(at: dir)
        log("已删除 \(dir.path)")
    } catch {
        log("删除失败:\(error)")
    }

default:
    print("""
    用法:perch-probe [--dir 文件夹] <命令>
    默认文件夹:\(defaultDir.path)

      write                 写一个带时间的小文件
      write --every 10      每 10 秒写一个
      watch                 监听文件夹变化,另一台 Mac 的文件到达时打印延迟
      status                列出所有文件:是否只在云端、下载状态
      read <文件>            读一个文件并计时(只在云端的文件会触发下载)
      evict <文件>           移除本地副本,让它变成只在云端
      bulk [数量]            一次写很多小文件(默认 500)
      scan                  全量检查一遍所有文件并计时
      readall [并发数]       并发读取所有只在云端的文件并计时(默认 8)
      clean                 删除整个测试文件夹
    """)
}

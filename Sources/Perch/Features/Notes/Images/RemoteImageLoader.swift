import AppKit
import CryptoKit

/// 网络图片(`![alt](https://…)`)的加载与缓存。
///
/// 引擎取图的接口是同步的,所以这里的约定是:内存 / 磁盘缓存命中就立刻返回图片;
/// 没命中先返回 nil(编辑器暂时显示源码),同时在后台下载,下载成功后回调
/// `onLoaded`,由调用方触发编辑器重新渲染。
///
/// 只发 https 请求以外的地址会被系统的 App Transport Security 拦下(Info.plist
/// 没有放宽 http),这类图片会按加载失败处理。
final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tech.xvanturing.Perch/RemoteImages", isDirectory: true)
    }

    /// 单张图片上限,超过的当作失败。
    static let maxBytes = 30 * 1024 * 1024
    /// 加载失败后多久内不再重试。编辑器每次重新渲染都会来问一遍,不设间隔会反复请求。
    static let retryInterval: TimeInterval = 300

    private let directory: URL
    private let session: URLSession
    private let lock = NSLock()
    private let memory = NSCache<NSURL, NSImage>()
    private var inFlight = Set<URL>()
    private var failedAt: [URL: Date] = [:]

    init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// 缓存命中返回图片;否则返回 nil 并在后台下载,成功后在主线程调用 `onLoaded`。
    func image(for url: URL, onLoaded: @escaping @Sendable () -> Void) -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let data = try? Data(contentsOf: cacheFile(for: url)), let image = NSImage(data: data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }
        fetch(url, onLoaded: onLoaded)
        return nil
    }

    private func fetch(_ url: URL, onLoaded: @escaping @Sendable () -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }

        lock.lock()
        if inFlight.contains(url) {
            lock.unlock()
            return
        }
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < Self.retryInterval {
            lock.unlock()
            return
        }
        inFlight.insert(url)
        lock.unlock()

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            var loaded = false
            if let data, (200..<300).contains(status), data.count <= Self.maxBytes, NSImage(data: data) != nil {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                loaded = (try? data.write(to: cacheFile(for: url), options: .atomic)) != nil
            }
            lock.lock()
            inFlight.remove(url)
            if !loaded { failedAt[url] = Date() }
            lock.unlock()
            if loaded {
                DispatchQueue.main.async { onLoaded() }
            }
        }.resume()
    }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}

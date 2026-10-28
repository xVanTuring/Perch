# iCloud Drive 同步验证

对应 [docs/icloud-drive-sync.md](../../docs/icloud-drive-sync.md) 第 10 节:写正式代码前,
在两台 Mac 上确认 iCloud 云盘的几个行为。小程序只读写 `iCloud 云盘/Perch-probe` 这个测试文件夹,
不碰 Perch 的数据,验证完可以用 `clean` 删掉。

下面把两台 Mac 叫 **A**(这台)和 **B**(另一台)。

## 0. 准备

在 A 上编译(同时包含 Apple 芯片和 Intel 两种架构,B 是哪种都能跑):

```sh
cd ~/agents-home/Perch
swiftc -O -target arm64-apple-macos15  tools/sync-probe/probe.swift -o /tmp/probe-arm64
swiftc -O -target x86_64-apple-macos15 tools/sync-probe/probe.swift -o /tmp/probe-x86
lipo -create /tmp/probe-arm64 /tmp/probe-x86 -output ~/perch-probe
```

把 `~/perch-probe` 拷到 B 的主目录(隔空投送、U 盘都可以)。B 上如果提示「无法验证开发者」,
运行一次 `xattr -d com.apple.quarantine ~/perch-probe`。

第一次运行时如果系统弹窗询问「终端」能否访问 iCloud 云盘里的文件,点允许,并**记下有没有弹窗**
(这关系到正式的 Perch 会不会也弹)。

## 1. 写入能不能同步过去 + 3. 有没有变化通知 + 4. 延迟

B 上先开始监听:

```sh
~/perch-probe watch
```

A 上每 10 秒写一个文件:

```sh
~/perch-probe write --every 10
```

在 B 的输出里看:

- 有没有出现 `← 来自 <A 的名字>,延迟 x 秒` 这样的行 → 写入能同步过去(第 1 项),
  并且 FSEvents 能通知到(第 3 项)。
- 延迟大概多少秒(第 4 项)。让它跑两三分钟,看看延迟稳不稳定。

然后两边对调(A 监听、B 写入)再跑一次。

## 2. 只在云端的文件

在 B 上:

```sh
~/perch-probe status                        # 看文件列表,挑一个 A 写的文件
~/perch-probe evict "<上面列出的完整路径>"     # 让它变成只在云端
~/perch-probe status                        # 这个文件应该显示 只在云端=true
~/perch-probe read "<同一个路径>"             # 读它:能不能读到内容、用了多久
```

如果 `evict` 报错,在 Finder 里打开「iCloud 云盘/Perch-probe」,右键文件 →「移除下载项」,
再接着跑 `status` 和 `read`。

要记下的:

- `status` 里「下载状态」这一列有没有值(不是「无」)→ 第 2 项的后半句:没有 iCloud 权限的程序
  能不能判断文件是否已下载。
- `read` 能不能读到内容、用了多久。

## 5. 文件多了以后全量检查要多久

A 上一次写 500 个小文件:

```sh
~/perch-probe bulk 500
```

等 B 上同步完(B 的 `status` 里文件数不再增加),在 B 上:

```sh
~/perch-probe scan
```

## 结束

两边都可以删掉测试文件夹:

```sh
~/perch-probe clean
```

把每一步的输出(或者截图)发给我就行,尤其是:有没有弹窗、延迟、`status` 的下载状态、
`read` 的结果和用时、`scan` 的用时。

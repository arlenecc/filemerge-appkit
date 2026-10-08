import Testing
import Foundation
import Darwin
import FileMergeCore

/// A. FMFileScanner 扫描器测试用例（A1–A6）
final class FileScannerTests {
    let root = FMSupport.makeTemporaryDirectory("scan")
    let scanner = FMFileScanner()

    deinit {
        // 不可读目录在用例内部已恢复权限
        FMSupport.removeTree(root)
    }

    /// A1 递归扫描嵌套目录，返回每个文件的绝对/相对路径与大小
    @Test("A1 递归扫描嵌套目录并记录路径与大小")
    func scanNestedDirectoriesCollectsAllFiles() {
        FMSupport.writeFile(root: root, relativePath: "a.txt", content: "alpha")
        FMSupport.writeFile(root: root, relativePath: "sub1/b.txt", content: "beta")
        FMSupport.writeFile(root: root, relativePath: "sub1/sub2/c.txt", content: "gamma")

        let result = try? scanner.scanRoot(root, origin: .primary, cancelled: nil)

        #expect(result != nil)
        guard let result else { return }
        #expect(result.fileCount == 3)

        let relPaths = Set(result.files.map(\.relativePath))
        #expect(relPaths == ["a.txt", "sub1/b.txt", "sub1/sub2/c.txt"])

        // 相对路径必须 Unicode 升序
        let sorted = result.files.map(\.relativePath)
        #expect(sorted == sorted.sorted())

        // 绝对路径与大小正确
        guard let first = result.files.first else { return }
        #expect(first.rootPath == root)
        #expect(first.absolutePath == FMSupport.join(root, first.relativePath))
        #expect(first.fileSize > 0)
        #expect(first.origin == .primary)
    }

    /// A2 文件数量与总字节数统计正确
    @Test("A2 统计文件数与总字节数")
    func scanComputesCountAndTotalBytes() {
        FMSupport.writeFile(root: root, relativePath: "x.txt", content: "12345")           // 5 字节
        FMSupport.writeFile(root: root, relativePath: "d/y.txt", content: "1234567890")    // 10 字节

        let result = try? scanner.scanRoot(root, origin: .secondary, cancelled: nil)

        #expect(result?.fileCount == 2)
        #expect(result?.totalBytes == 15)
        #expect(result?.files.first?.origin == .secondary)
    }

    /// A3 根目录不可读 → rootUnreadable 错误（不静默返回空结果）
    @Test("A3 根目录不可读报错")
    func unreadableRootReturnsError() {
        let sub = FMSupport.join(root, "locked")
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        FMSupport.writeFile(root: sub, relativePath: "inside.txt", content: "hidden")
        chmod(sub, 0o000)
        defer { chmod(sub, 0o755) }

        do {
            _ = try scanner.scanRoot(sub, origin: .primary, cancelled: nil)
            Issue.record("应当抛出 rootUnreadable")
        } catch let e as FMError {
            #expect(e.code == .rootUnreadable)
        } catch {
            Issue.record("错误类型不符: \(error)")
        }
    }

    /// A4 子目录不可读 → 记录警告并跳过，其余文件照常收集
    @Test("A4 子目录不可读产生警告并跳过")
    func unreadableSubdirectoryWarnsAndSkips() {
        FMSupport.writeFile(root: root, relativePath: "ok.txt", content: "visible")
        let lockedDir = FMSupport.join(root, "locked")
        try? FileManager.default.createDirectory(atPath: lockedDir, withIntermediateDirectories: true)
        FMSupport.writeFile(root: lockedDir, relativePath: "secret.txt", content: "nope")
        chmod(lockedDir, 0o000)
        defer { chmod(lockedDir, 0o755) }

        let result = try? scanner.scanRoot(root, origin: .primary, cancelled: nil)

        #expect(result?.fileCount == 1)
        #expect(result?.files.first?.relativePath == "ok.txt")
        #expect((result?.warnings.count ?? 0) >= 1, "不可读子目录必须产生警告")
    }

    /// A5 符号链接（文件或目录）不作为普通文件收集
    @Test("A5 符号链接不收集")
    func symlinksAreNotCollected() {
        FMSupport.writeFile(root: root, relativePath: "real.txt", content: "real")
        let realPath = FMSupport.join(root, "real.txt")
        let dirPath = FMSupport.join(root, "realdir")
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        FMSupport.writeFile(root: dirPath, relativePath: "inner.txt", content: "inner")

        try? FileManager.default.createSymbolicLink(
            atPath: FMSupport.join(root, "link.txt"), withDestinationPath: realPath)
        try? FileManager.default.createSymbolicLink(
            atPath: FMSupport.join(root, "dirlink"), withDestinationPath: dirPath)

        let result = try? scanner.scanRoot(root, origin: .primary, cancelled: nil)

        let relPaths = Set(result?.files.map(\.relativePath) ?? [])
        #expect(relPaths == ["real.txt", "realdir/inner.txt"])
    }

    /// A6 扫描过程支持取消
    @Test("A6 扫描支持取消")
    func scanCanBeCancelled() {
        for i in 0 ..< 50 {
            FMSupport.writeFile(root: root, relativePath: "dir\(i)/file\(i).txt", content: "payload")
        }

        var cancelled = true  // 立即取消
        do {
            _ = try scanner.scanRoot(root, origin: .primary, cancelled: { cancelled })
            Issue.record("应当抛出 cancelled")
        } catch let e as FMError {
            #expect(e.code == .cancelled)
        } catch {
            Issue.record("错误类型不符: \(error)")
        }

        cancelled = false
        let result = try? scanner.scanRoot(root, origin: .primary, cancelled: nil)
        #expect(result?.fileCount == 50)
    }

    /// A7 根路径以符号链接短路径传入时（如 /var 与 /private/var），
    /// 相对路径剥离仍必须正确——不得把绝对路径误当作相对路径。
    /// （真实场景：用户手输/外部注入 /tmp、/var 等短路径，而枚举器输出 /private/... 真实路径）
    @Test("A7 根路径为符号链接短路径时相对路径正确")
    func aliasedRootPathStripsPrefixCorrectly() throws {
        // makeTemporaryDirectory 返回 realpath 化路径（macOS 上为 /private/var/...）；
        // /var 是 /private/var 的符号链接，用短表示作为根路径传入
        guard root.hasPrefix("/private/var") else { return }  // 环境不满足时跳过
        let aliasRoot = "/var" + root.dropFirst("/private/var".count)

        FMSupport.writeFile(root: root, relativePath: "a.txt", content: "alpha")
        FMSupport.writeFile(root: root, relativePath: "sub/b.txt", content: "beta")

        let result = try scanner.scanRoot(aliasRoot, origin: .primary, cancelled: nil)

        let relPaths = Set(result.files.map(\.relativePath))
        #expect(relPaths == ["a.txt", "sub/b.txt"])

        // 防回归断言：相对路径绝不能携带路径解析残留
        for f in result.files {
            #expect(!f.relativePath.hasPrefix("/"), "相对路径不应以 / 开头: \(f.relativePath)")
            #expect(f.absolutePath.hasPrefix("/private/var"), "绝对路径应为真实路径表示")
        }
    }

    /// A8 不可读条目极多时警告封顶：50 条明细 + 1 条汇总行
    @Test("A8 扫描警告封顶")
    func warningsAreCapped() throws {
        // 60 个不可读子目录 → 60 次枚举错误 → 明细封顶 50 + 汇总 1 条
        for i in 0 ..< 60 {
            let dir = FMSupport.join(root, "locked\(i)")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FMSupport.writeFile(root: dir, relativePath: "x.txt", content: "x")
            chmod(dir, 0o000)
        }
        defer {
            for i in 0 ..< 60 {
                chmod(FMSupport.join(root, "locked\(i)"), 0o755)
            }
        }

        let result = try scanner.scanRoot(root, origin: .primary, cancelled: nil)

        #expect(result.fileCount == 0, "不可读子目录中的文件不应计入")
        #expect(result.warnings.count == 51, "50 条明细 + 1 条汇总行，实际 \(result.warnings.count)")
        #expect(result.warnings.last?.contains("未逐条列出") == true, "末条应为汇总行")
    }
}

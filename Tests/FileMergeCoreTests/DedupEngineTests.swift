import Testing
import Foundation
import FileMergeCore

/// C. FMDedupEngine 全局排重测试用例（C1–C6）
final class DedupEngineTests {
    let primaryRoot = FMSupport.makeTemporaryDirectory("dedup-p")
    let secondaryRoot = FMSupport.makeTemporaryDirectory("dedup-s")
    let hasher = FMFileHasher()
    let engine = FMDedupEngine()

    deinit {
        FMSupport.removeTree(primaryRoot)
        FMSupport.removeTree(secondaryRoot)
    }

    private func rec(_ root: String, _ rel: String, _ origin: FMFileOrigin) throws -> FMFileRecord {
        try #require(FMSupport.record(root: root, relativePath: rel, origin: origin))
    }

    /// C1 主目录与副目录同内容 → 副目录副本被判重复剔除（主目录优先）
    @Test("C1 主目录优先剔除副目录重复")
    func primaryWinsOverSecondary() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a/one.txt", content: "same-content")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "b/two.txt", content: "same-content")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "unique.txt", content: "only-in-secondary")

        let p1 = try rec(primaryRoot, "a/one.txt", .primary)
        let s1 = try rec(secondaryRoot, "b/two.txt", .secondary)
        let s2 = try rec(secondaryRoot, "unique.txt", .secondary)

        let result = try #require(try engine.dedupPrimary([p1], secondary: [s1, s2], hasher: hasher, progress: nil, cancelled: nil))

        #expect(result.uniquePrimary.map(\.relativePath) == ["a/one.txt"])
        #expect(result.uniqueSecondary.map(\.relativePath) == ["unique.txt"], "与主目录重复的副目录文件应被剔除")
        #expect(result.duplicateCount == 1)
    }

    /// C2 主目录内部重复 → 按相对路径 Unicode 升序保留第一个
    @Test("C2 主目录内部重复按 Unicode 升序保留")
    func primaryInternalDupKeepsFirstByUnicode() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "b/second.txt", content: "dup-content")
        FMSupport.writeFile(root: primaryRoot, relativePath: "a/first.txt", content: "dup-content")
        FMSupport.writeFile(root: primaryRoot, relativePath: "c/third.txt", content: "dup-content")

        let records = try ["a/first.txt", "b/second.txt", "c/third.txt"].map { try rec(primaryRoot, $0, .primary) }
        // 故意乱序传入，验证引擎自身按相对路径 Unicode 升序决策
        let shuffled = [records[2], records[0], records[1]]

        let result = try #require(try engine.dedupPrimary(shuffled, secondary: [], hasher: hasher, progress: nil, cancelled: nil))

        #expect(result.uniquePrimary.map(\.relativePath) == ["a/first.txt"])
        #expect(result.duplicateCount == 2)
    }

    /// C3 副目录内部重复 → 同样按相对路径 Unicode 升序保留第一个
    @Test("C3 副目录内部重复按 Unicode 升序保留")
    func secondaryInternalDupKeepsFirstByUnicode() throws {
        FMSupport.writeFile(root: secondaryRoot, relativePath: "z.txt", content: "s-dup")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "m.txt", content: "s-dup")

        let records = try ["z.txt", "m.txt"].map { try rec(secondaryRoot, $0, .secondary) }
        let result = try #require(try engine.dedupPrimary([], secondary: records, hasher: hasher, progress: nil, cancelled: nil))

        #expect(result.uniqueSecondary.map(\.relativePath) == ["m.txt"])
        #expect(result.duplicateCount == 1)
    }

    /// C4 副目录独有内容全部保留
    @Test("C4 副目录独有内容全部保留")
    func secondaryUniqueSurvives() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "p.txt", content: "P")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "s1.txt", content: "S1")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "s2.txt", content: "S2")

        let p = try rec(primaryRoot, "p.txt", .primary)
        let s1 = try rec(secondaryRoot, "s1.txt", .secondary)
        let s2 = try rec(secondaryRoot, "s2.txt", .secondary)

        let result = try #require(try engine.dedupPrimary([p], secondary: [s1, s2], hasher: hasher, progress: nil, cancelled: nil))

        #expect(result.uniquePrimary.count == 1)
        #expect(result.uniqueSecondary.count == 2)
        #expect(result.duplicateCount == 0)
    }

    /// C5 空目录/单边为空时结果正确
    @Test("C5 空目录边界")
    func emptySides() throws {
        let resultBothEmpty = try #require(try engine.dedupPrimary([], secondary: [], hasher: hasher, progress: nil, cancelled: nil))
        #expect(resultBothEmpty.uniquePrimary.isEmpty)
        #expect(resultBothEmpty.uniqueSecondary.isEmpty)
        #expect(resultBothEmpty.duplicateCount == 0)

        FMSupport.writeFile(root: primaryRoot, relativePath: "only-p.txt", content: "only")
        let p = try rec(primaryRoot, "only-p.txt", .primary)
        let resultOnlyPrimary = try #require(try engine.dedupPrimary([p], secondary: [], hasher: hasher, progress: nil, cancelled: nil))
        #expect(resultOnlyPrimary.uniquePrimary.count == 1)
        #expect(resultOnlyPrimary.uniqueSecondary.isEmpty)
    }

    /// C6 排重阶段支持取消
    @Test("C6 排重支持取消")
    func dedupCanBeCancelled() throws {
        var files: [FMFileRecord] = []
        for i in 0 ..< 20 {
            FMSupport.writeFile(root: primaryRoot, relativePath: "dir\(i % 2)/f\(i).txt", content: "c\(i % 3)")
            files.append(try rec(primaryRoot, "dir\(i % 2)/f\(i).txt", .primary))
        }

        var cancelled = true
        do {
            _ = try engine.dedupPrimary(files, secondary: [], hasher: hasher, progress: nil, cancelled: { cancelled })
            Issue.record("应当抛出 cancelled")
        } catch let e as FMError {
            #expect(e.code == .cancelled)
        } catch {
            Issue.record("错误类型不符: \(error)")
        }

        cancelled = false
        let result = try #require(try engine.dedupPrimary(files, secondary: [], hasher: hasher, progress: nil, cancelled: nil))
        // 20 个文件 3 种内容 → 保留 3 个
        #expect(result.uniquePrimary.count == 3)
        #expect(result.duplicateCount == 17)
    }

    /// C7 哈希失败文件不得静默消失：进 warnings、不进唯一列表
    /// （两个同尺寸文件才能进入头部哈希阶段；一个 chmod 000 模拟读取失败）
    @Test("C7 哈希失败进 warnings")
    func hashFailureSurfacesWarning() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "ok.txt", content: "XYZ")
        FMSupport.writeFile(root: primaryRoot, relativePath: "bad.txt", content: "XYZ")
        let badPath = FMSupport.join(primaryRoot, "bad.txt")
        chmod(badPath, 0o000)
        defer { chmod(badPath, 0o644) }

        let ok = try rec(primaryRoot, "ok.txt", .primary)
        let bad = try rec(primaryRoot, "bad.txt", .primary)
        let result = try #require(try engine.dedupPrimary([ok, bad], secondary: [], hasher: hasher, progress: nil, cancelled: nil))

        #expect(result.uniquePrimary.map(\.relativePath) == ["ok.txt"], "可读文件正常保留")
        #expect(result.duplicateCount == 0)
        #expect(result.warnings.count == 1, "哈希失败应有且仅有一条告警")
        #expect(result.warnings.first?.contains("bad.txt") == true, "告警应指明被排除的文件")
    }
}

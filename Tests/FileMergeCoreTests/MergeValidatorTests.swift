import Testing
import Foundation
import FileMergeCore

/// E. FMMergeValidator 路径安全校验测试用例（E1–E5）
final class MergeValidatorTests {
    let base = FMSupport.makeTemporaryDirectory("val")

    deinit { FMSupport.removeTree(base) }

    /// E1 最终目录与主/副目录经 realpath 解析后相同 → 拒绝
    @Test("E1 相同路径拒绝")
    func identicalPathsRejected() {
        let primary = FMSupport.join(base, "primary")
        try? FileManager.default.createDirectory(atPath: primary, withIntermediateDirectories: true)
        let secondary = FMSupport.join(base, "secondary")
        try? FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: true)

        let err = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: primary)
        #expect(err != nil, "最终目录等于主目录必须拒绝")
        #expect((err as NSError?)?.code == FMError.Code.validationFailed.rawValue)

        let err2 = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: secondary)
        #expect(err2 != nil, "最终目录等于副目录必须拒绝")
    }

    /// E2 祖先/后代关系（任一方向）→ 拒绝
    @Test("E2 祖先后代关系拒绝")
    func ancestorDescendantRejected() {
        let primary = FMSupport.join(base, "p2")
        let nested = FMSupport.join(primary, "child")
        try? FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let secondary = FMSupport.join(base, "s2")
        try? FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: true)

        // 最终目录是主目录的后代
        let err1 = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: nested)
        #expect(err1 != nil, "最终目录位于主目录内部必须拒绝")

        // 最终目录是主目录的祖先
        let err2 = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: base)
        #expect(err2 != nil, "最终目录包含主目录必须拒绝")

        // 主目录与副目录互为祖先/后代也必须拒绝
        let err3 = FMMergeValidator.validatePrimary(base, secondary: primary, final: FMSupport.join(base, "out"))
        #expect(err3 != nil, "副目录位于主目录内部必须拒绝")
    }

    /// E3 符号链接别名 → 拒绝（realpath 解析）
    @Test("E3 符号链接别名拒绝")
    func symlinkAliasRejected() {
        let realDir = FMSupport.join(base, "real3")
        try? FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        let alias = FMSupport.join(base, "alias3")
        try? FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: realDir)

        let secondary = FMSupport.join(base, "s3")
        try? FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: true)

        // 最终目录是主目录的符号链接别名
        let err = FMMergeValidator.validatePrimary(realDir, secondary: secondary, final: alias)
        #expect(err != nil, "符号链接别名指向主目录必须拒绝")

        // 符号链接别名指向主目录的祖先
        let errAncestor = FMMergeValidator.validatePrimary(FMSupport.join(realDir, "sub"),
                                                           secondary: secondary,
                                                           final: alias)
        #expect(errAncestor != nil, "别名指向主目录的祖先必须拒绝")

        // 无关目录的别名应当通过
        let other = FMSupport.join(base, "other3")
        try? FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let ok = FMMergeValidator.validatePrimary(realDir, secondary: secondary, final: other)
        #expect(ok == nil)
    }

    /// E4 大小写不敏感文件系统上的大小写别名 → 拒绝
    @Test("E4 大小写别名拒绝")
    func caseAliasRejected() {
        let primary = FMSupport.join(base, "CaseDir4")
        try? FileManager.default.createDirectory(atPath: primary, withIntermediateDirectories: true)
        let secondary = FMSupport.join(base, "s4")
        try? FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: true)

        // 大小写不敏感文件系统（macOS 默认 APFS）下，仅大小写不同指向同一目录
        let swapped = FMSupport.join(base, "casedir4")
        #expect(FileManager.default.fileExists(atPath: swapped), "大小写变体应指向已存在目录")

        let err = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: swapped)
        #expect(err != nil, "大小写别名必须拒绝")
    }

    /// E5 最终目录不存在 → 允许；但主/副目录不存在 → 拒绝
    @Test("E5 不存在路径的处理")
    func nonexistentPaths() {
        let primary = FMSupport.join(base, "p5")
        try? FileManager.default.createDirectory(atPath: primary, withIntermediateDirectories: true)
        let secondary = FMSupport.join(base, "s5")
        try? FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: true)

        // 最终目录不存在 → 允许（合并时创建）
        let ok = FMSupport.join(base, "out5-new")
        #expect(!FileManager.default.fileExists(atPath: ok))
        #expect(FMMergeValidator.validatePrimary(primary, secondary: secondary, final: ok) == nil)

        // 主目录不存在 → 拒绝
        let ghostPrimary = FMSupport.join(base, "ghost5")
        let err = FMMergeValidator.validatePrimary(ghostPrimary, secondary: secondary, final: ok)
        #expect(err != nil, "主目录不存在必须拒绝")

        // 副目录不存在 → 拒绝
        let ghostSecondary = FMSupport.join(base, "ghost5b")
        let err2 = FMMergeValidator.validatePrimary(primary, secondary: ghostSecondary, final: ok)
        #expect(err2 != nil, "副目录不存在必须拒绝")

        // 最终目录是已存在的普通文件 → 拒绝
        let filePath = FMSupport.writeFile(root: base, relativePath: "asfile5", content: "x")
        let err3 = FMMergeValidator.validatePrimary(primary, secondary: secondary, final: filePath)
        #expect(err3 != nil, "最终目录是文件必须拒绝")
    }

    /// realpath 解析：最长存在祖先 + 尾部拼接
    @Test("E6 resolvedPath 解析存在祖先并拼接尾部")
    func resolvedPathResolvesExistingAncestor() {
        let realDir = FMSupport.join(base, "real6")
        try? FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        let alias = FMSupport.join(base, "alias6")
        try? FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: realDir)

        // 存在的符号链接路径应解析到真实路径
        let resolved = FMMergeValidator.resolvedPath(forPath: alias)
        #expect(resolved.caseInsensitiveCompare(realDir) == .orderedSame)

        // 不存在的尾部应拼在已解析祖先之后
        let ghost = FMSupport.join(alias, "new/child")
        let resolvedGhost = FMMergeValidator.resolvedPath(forPath: ghost)
        #expect(resolvedGhost.caseInsensitiveCompare(FMSupport.join(realDir, "new/child")) == .orderedSame)
    }
}

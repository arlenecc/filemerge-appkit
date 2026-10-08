import Testing
import Foundation
import FileMergeCore

/// F. FMMergeEngine 合并测试用例（F1–F13）
final class MergeEngineTests {
    let primaryRoot = FMSupport.makeTemporaryDirectory("merge-p")
    let secondaryRoot = FMSupport.makeTemporaryDirectory("merge-s")
    let finalRoot = FMSupport.makeTemporaryDirectory("merge-f")
    let hasher = FMFileHasher()

    deinit {
        FMSupport.removeTree(primaryRoot)
        FMSupport.removeTree(secondaryRoot)
        FMSupport.removeTree(finalRoot)
    }

    private func rec(_ root: String, _ rel: String, _ origin: FMFileOrigin) throws -> FMFileRecord {
        try #require(FMSupport.record(root: root, relativePath: rel, origin: origin))
    }

    private func engine() -> FMMergeEngine {
        FMMergeEngine(hasher: hasher, workerCount: 2)
    }

    private func contents(at rel: String) -> String? {
        let path = FMSupport.join(finalRoot, rel)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func listFinal() -> Set<String> {
        var found = Set<String>()
        let fm = FileManager.default
        if let e = fm.enumerator(atPath: finalRoot) {
            while let item = e.nextObject() as? String {
                found.insert(item)
            }
        }
        return found
    }

    private func planActions(_ plan: [FMMergePlanItem]) -> [String: FMPlanAction] {
        Dictionary(uniqueKeysWithValues: plan.map { ($0.source.relativePath, $0.action) })
    }

    /// F1 主目录唯一文件按主目录结构写入最终目录
    @Test("F1 主目录结构写入最终目录")
    func primaryLayoutWrittenToFinal() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        FMSupport.writeFile(root: primaryRoot, relativePath: "sub/b.txt", content: "B")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "c.txt", content: "C")

        let plan = engine().buildPlanPrimary(
            [try rec(primaryRoot, "a.txt", .primary), try rec(primaryRoot, "sub/b.txt", .primary)],
            secondary: [try rec(secondaryRoot, "c.txt", .secondary)],
            finalRoot: finalRoot, cancelled: nil)

        let actions = planActions(plan)
        #expect(actions["a.txt"] == .copy)
        #expect(actions["sub/b.txt"] == .copy)
        #expect(actions["c.txt"] == .copy)

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.copiedCount == 3)
        #expect(contents(at: "a.txt") == "A")
        #expect(contents(at: "sub/b.txt") == "B")
        #expect(contents(at: "c.txt") == "C")
    }

    /// F2 副目录独有文件按其相对路径写入最终目录
    @Test("F2 副目录独有文件按相对路径写入")
    func secondaryUniqueWrittenByRelativePath() throws {
        FMSupport.writeFile(root: secondaryRoot, relativePath: "x/y.txt", content: "Y")

        let plan = engine().buildPlanPrimary([], secondary: [try rec(secondaryRoot, "x/y.txt", .secondary)], finalRoot: finalRoot, cancelled: nil)
        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))

        #expect(outcome.copiedCount == 1)
        #expect(contents(at: "x/y.txt") == "Y")
    }

    /// F3 目标已存在且内容相同 → 跳过（幂等：二次合并零写入、结果一致）
    @Test("F3 幂等跳过")
    func idempotentSkip() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")

        let plan1 = engine().buildPlanPrimary([try rec(primaryRoot, "a.txt", .primary)], secondary: [], finalRoot: finalRoot, cancelled: nil)
        _ = try #require(try engine().executePlan(plan1, progress: nil, cancelled: nil))
        let afterFirst = listFinal()

        let plan2 = engine().buildPlanPrimary([try rec(primaryRoot, "a.txt", .primary)], secondary: [], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan2)["a.txt"] == .skip, "内容相同时应判定为跳过")

        let outcome2 = try #require(try engine().executePlan(plan2, progress: nil, cancelled: nil))
        #expect(outcome2.copiedCount == 0)
        #expect(outcome2.overwrittenCount == 0)
        #expect(outcome2.skippedCount == 1)
        #expect(listFinal() == afterFirst, "二次合并不得改变最终目录")
    }

    /// F4 主目录文件与目标同名但内容不同 → 覆盖
    @Test("F4 主目录同名不同内容覆盖")
    func primaryOverwritesDifferentTarget() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "b.txt", content: "NEW")
        FMSupport.writeFile(root: finalRoot, relativePath: "b.txt", content: "OLD")

        let plan = engine().buildPlanPrimary([try rec(primaryRoot, "b.txt", .primary)], secondary: [], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan)["b.txt"] == .overwrite)

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.overwrittenCount == 1)
        #expect(contents(at: "b.txt") == "NEW")
    }

    /// F5 副目录冲突 → 重命名 "s (1).txt"；重复合并不产生冗余副本
    @Test("F5 冲突重命名且二次合并幂等")
    func conflictRenameAndIdempotentRerun() throws {
        FMSupport.writeFile(root: secondaryRoot, relativePath: "s.txt", content: "S-CONTENT")
        FMSupport.writeFile(root: finalRoot, relativePath: "s.txt", content: "TARGET")

        // 第一次合并：重命名
        let plan1 = engine().buildPlanPrimary([], secondary: [try rec(secondaryRoot, "s.txt", .secondary)], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan1)["s.txt"] == .rename)
        let renameItem = try #require(plan1.first)
        #expect(renameItem.targetPath == FMSupport.join(finalRoot, "s (1).txt"))

        let outcome1 = try #require(try engine().executePlan(plan1, progress: nil, cancelled: nil))
        #expect(outcome1.renamedCount == 1)
        #expect(contents(at: "s.txt") == "TARGET")
        #expect(contents(at: "s (1).txt") == "S-CONTENT")

        // 第二次合并：同名冲突、候选重命名路径内容一致 → 幂等跳过，不得产生 "s (2).txt"
        let plan2 = engine().buildPlanPrimary([], secondary: [try rec(secondaryRoot, "s.txt", .secondary)], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan2)["s.txt"] == .skip, "重命名条目重复合并应幂等跳过")
        let outcome2 = try #require(try engine().executePlan(plan2, progress: nil, cancelled: nil))
        #expect(outcome2.skippedCount == 1)
        #expect(outcome2.renamedCount == 0)
        #expect(listFinal() == ["s.txt", "s (1).txt"])
    }

    /// F6 覆盖目标为目录 → 拒绝该条目并记录错误，不递归删除子树
    @Test("F6 覆盖目标为目录拒绝且子树完整")
    func overwriteTargetIsDirectoryRefused() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "dpath", content: "I-AM-A-FILE")
        // 目标处为目录，内含文件
        let targetDir = FMSupport.join(finalRoot, "dpath")
        try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        FMSupport.writeFile(root: finalRoot, relativePath: "dpath/inner.txt", content: "PRECIOUS")

        let plan = engine().buildPlanPrimary([try rec(primaryRoot, "dpath", .primary)], secondary: [], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan)["dpath"] == .error)
        #expect(plan.first?.errorMessage != nil, "拒绝条目必须携带错误信息")

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.errorCount == 1)
        // 子树必须完整保留
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: FMSupport.join(finalRoot, "dpath/inner.txt"), isDirectory: &isDir))
        #expect(contents(at: "dpath/inner.txt") == "PRECIOUS")
    }

    /// F7 计划阶段是干跑：串行决策不修改最终目录
    @Test("F7 计划阶段为干跑")
    func planIsDryRun() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        let before = listFinal()

        _ = engine().buildPlanPrimary([try rec(primaryRoot, "a.txt", .primary)], secondary: [], finalRoot: finalRoot, cancelled: nil)

        #expect(listFinal() == before, "仅生成计划不得写入最终目录")
    }

    /// F8 各类结果统计准确（写入/覆盖/跳过/重命名/错误）
    @Test("F8 合并统计准确")
    func outcomeCounting() throws {
        // 主目录：a 复制、b 覆盖、c 跳过、dpath 错误
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        FMSupport.writeFile(root: primaryRoot, relativePath: "b.txt", content: "B-NEW")
        FMSupport.writeFile(root: primaryRoot, relativePath: "c.txt", content: "C")
        FMSupport.writeFile(root: primaryRoot, relativePath: "dpath", content: "FILE")
        // 最终目录既有状态
        FMSupport.writeFile(root: finalRoot, relativePath: "b.txt", content: "B-OLD")
        FMSupport.writeFile(root: finalRoot, relativePath: "c.txt", content: "C")
        FMSupport.writeFile(root: finalRoot, relativePath: "s.txt", content: "T")
        try? FileManager.default.createDirectory(atPath: FMSupport.join(finalRoot, "dpath"), withIntermediateDirectories: true)
        FMSupport.writeFile(root: finalRoot, relativePath: "dpath/keep.txt", content: "K")
        // 副目录：s 冲突重命名
        FMSupport.writeFile(root: secondaryRoot, relativePath: "s.txt", content: "S")

        let records = try #require(FMSupport.record(root: primaryRoot, relativePath: "dpath", origin: .primary))
        let plan = engine().buildPlanPrimary(
            [
                try rec(primaryRoot, "a.txt", .primary),
                try rec(primaryRoot, "b.txt", .primary),
                try rec(primaryRoot, "c.txt", .primary),
                records,
            ],
            secondary: [try rec(secondaryRoot, "s.txt", .secondary)],
            finalRoot: finalRoot, cancelled: nil)

        let actions = planActions(plan)
        #expect(actions["a.txt"] == .copy)
        #expect(actions["b.txt"] == .overwrite)
        #expect(actions["c.txt"] == .skip)
        #expect(actions["dpath"] == .error)
        #expect(actions["s.txt"] == .rename)

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.copiedCount == 1)
        #expect(outcome.overwrittenCount == 1)
        #expect(outcome.skippedCount == 1)
        #expect(outcome.renamedCount == 1)
        #expect(outcome.errorCount == 1)
        #expect(outcome.errorMessages.count == 1)
        #expect(contents(at: "b.txt") == "B-NEW")
        #expect(contents(at: "s.txt") == "T")
        #expect(contents(at: "s (1).txt") == "S")
        #expect(contents(at: "dpath/keep.txt") == "K")
    }

    /// F9 合并过程支持取消
    @Test("F9 合并支持取消")
    func mergeCanBeCancelled() throws {
        var paths: [FMFileRecord] = []
        for i in 0 ..< 30 {
            FMSupport.writeFile(root: primaryRoot, relativePath: "d\(i)/f\(i).txt", content: "p\(i)")
            paths.append(try rec(primaryRoot, "d\(i)/f\(i).txt", .primary))
        }
        let plan = engine().buildPlanPrimary(paths, secondary: [], finalRoot: finalRoot, cancelled: nil)

        var cancelled = true
        do {
            _ = try engine().executePlan(plan, progress: nil, cancelled: { cancelled })
            Issue.record("应当抛出 cancelled")
        } catch let e as FMError {
            #expect(e.code == .cancelled)
        } catch {
            Issue.record("错误类型不符: \(error)")
        }

        cancelled = false
        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.copiedCount == 30)
    }

    /// F10 覆盖动作改为"临时文件复制成功后再交换"：
    /// 复制中途失败（源不可读）时旧目标文件必须原样保留，不得先删后拷
    @Test("F10 覆盖失败保留旧文件")
    func overwriteFailureKeepsOldFile() throws {
        let oldPath = FMSupport.join(finalRoot, "a.txt")
        try Data("OLD".utf8).write(to: URL(fileURLWithPath: oldPath))
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "NEW")
        let src = FMSupport.join(primaryRoot, "a.txt")
        chmod(src, 0o000)  // 源不可读 → 复制必失败
        defer { chmod(src, 0o644) }

        let plan = engine().buildPlanPrimary(
            [try rec(primaryRoot, "a.txt", .primary)],
            secondary: [],
            finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan)["a.txt"] == .overwrite, "计划期内容比较失败视为不同 → 覆盖")

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.errorCount > 0, "复制失败应记错")
        #expect(outcome.overwrittenCount == 0)

        let old = FileManager.default.contents(atPath: oldPath)
        #expect(old != nil, "旧目标文件必须保留")
        #expect(String(data: try #require(old), encoding: .utf8) == "OLD", "旧文件内容不得被破坏")
        #expect(!FileManager.default.fileExists(atPath: oldPath + ".fm-tmp-0"), "失败后不得残留临时文件")
    }

    /// F11 计划构建支持取消：首次探测即返回取消 → 空计划
    @Test("F11 buildPlan 支持取消")
    func buildPlanHonoursCancellation() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        let plan = engine().buildPlanPrimary(
            [try rec(primaryRoot, "a.txt", .primary)],
            secondary: [],
            finalRoot: finalRoot,
            cancelled: { true })
        #expect(plan.isEmpty)
    }

    /// F12 覆盖执行期目标被替换为目录：拒绝覆盖、目录子树原样保留、无临时文件残留。
    /// 回归：replaceItemAt 会把目录无条件换成文件（递归删除子树），必须先判目录再替换
    @Test("F12 执行期目录目标拒绝覆盖且保留子树")
    func overwriteExecTimeDirectoryRejected() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "NEW")
        FMSupport.writeFile(root: finalRoot, relativePath: "a.txt", content: "OLD")

        let plan = engine().buildPlanPrimary(
            [try rec(primaryRoot, "a.txt", .primary)],
            secondary: [], finalRoot: finalRoot, cancelled: nil)
        #expect(planActions(plan)["a.txt"] == .overwrite)

        // 计划之后、执行之前，目标被外部替换为目录（含子文件）
        let targetPath = FMSupport.join(finalRoot, "a.txt")
        try FileManager.default.removeItem(atPath: targetPath)
        try FileManager.default.createDirectory(atPath: targetPath, withIntermediateDirectories: true)
        FMSupport.writeFile(root: finalRoot, relativePath: "a.txt/keep.txt", content: "K")

        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.overwrittenCount == 0)
        #expect(outcome.errorCount == 1, "执行期目录目标应记错拒绝")
        #expect(outcome.errorMessages.contains { $0.contains("目录") }, "错误信息应说明目录拒绝")
        #expect(contents(at: "a.txt/keep.txt") == "K", "目录子树必须原样保留")
        #expect(!FileManager.default.fileExists(atPath: targetPath + ".fm-tmp-0"), "失败后不得残留临时文件")
    }

    /// F13 覆盖成功路径：临时文件无残留、目标内容被原子替换
    @Test("F13 覆盖成功无临时文件残留")
    func overwriteSuccessLeavesNoResidue() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "NEW")
        FMSupport.writeFile(root: finalRoot, relativePath: "a.txt", content: "OLD")

        let plan = engine().buildPlanPrimary(
            [try rec(primaryRoot, "a.txt", .primary)],
            secondary: [], finalRoot: finalRoot, cancelled: nil)
        let outcome = try #require(try engine().executePlan(plan, progress: nil, cancelled: nil))
        #expect(outcome.overwrittenCount == 1)
        #expect(outcome.errorCount == 0)
        #expect(contents(at: "a.txt") == "NEW")
        #expect(!FileManager.default.fileExists(atPath: FMSupport.join(finalRoot, "a.txt") + ".fm-tmp-0"),
                "覆盖成功后不得残留临时文件")
    }
}

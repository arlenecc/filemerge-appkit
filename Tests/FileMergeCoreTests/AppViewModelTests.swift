import Testing
import Foundation
import Darwin
import FileMergeCore
import FileMergeUI

/// 委托回调记录器（线程安全）
final class VMRecorder: NSObject, FMAppViewModelDelegate {
    private let lock = NSLock()
    private(set) var changeCount = 0
    private(set) var logLines: [String] = []

    func viewModelDidChange(_ viewModel: FMAppViewModel) {
        lock.lock()
        changeCount += 1
        lock.unlock()
    }

    func viewModel(_ viewModel: FMAppViewModel, didAppendLogLine line: String) {
        lock.lock()
        logLines.append(line)
        lock.unlock()
    }
}

/// G. FMAppViewModel 状态机测试用例（G1–G10）
final class AppViewModelTests {
    let primaryRoot = FMSupport.makeTemporaryDirectory("vm-p")
    let secondaryRoot = FMSupport.makeTemporaryDirectory("vm-s")
    let finalRoot = FMSupport.makeTemporaryDirectory("vm-f")
    let queue = DispatchQueue(label: "vm-test-callback")

    deinit {
        FMSupport.removeTree(primaryRoot)
        FMSupport.removeTree(secondaryRoot)
        FMSupport.removeTree(finalRoot)
    }

    private func makeViewModel(recorder: VMRecorder? = nil) -> FMAppViewModel {
        let vm = FMAppViewModel()
        vm.callbackQueue = queue
        if let recorder = recorder { vm.delegate = recorder }
        vm.primaryPath = primaryRoot
        vm.secondaryPath = secondaryRoot
        vm.finalPath = finalRoot
        return vm
    }

    /// 轮询等待条件成立（ViewModel 内部为异步执行）
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// G1 初始状态：空闲、进度 0、目录按钮可用、分析/合并按钮不可用
    @Test("G1 初始状态正确")
    func initialState() {
        let vm = FMAppViewModel()
        #expect(vm.state == .idle)
        #expect(vm.progress == 0)
        #expect(vm.canPickDirectories)
        #expect(!vm.canStartAnalysis, "路径为空时不可开始分析")
        #expect(!vm.canStartMerge)
    }

    /// G2 三路径齐全才允许分析；缺一不可
    @Test("G2 路径齐全才允许分析")
    func canStartAnalysisRequiresAllPaths() {
        let vm = FMAppViewModel()
        vm.primaryPath = primaryRoot
        #expect(!vm.canStartAnalysis)
        vm.secondaryPath = secondaryRoot
        #expect(!vm.canStartAnalysis)
        vm.finalPath = finalRoot
        #expect(vm.canStartAnalysis)

        let vmEmpty = FMAppViewModel()
        vmEmpty.primaryPath = ""
        vmEmpty.secondaryPath = secondaryRoot
        vmEmpty.finalPath = finalRoot
        #expect(!vmEmpty.canStartAnalysis, "空字符串路径视为未设置")
    }

    /// G3 完整分析流程：状态迁移、结果产出、进度收敛、回调送达注入队列
    @Test("G3 分析流程状态迁移与结果")
    func analysisFlow() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "same")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "b.txt", content: "same")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "c.txt", content: "unique")

        let recorder = VMRecorder()
        let vm = makeViewModel(recorder: recorder)
        #expect(vm.canStartAnalysis)

        vm.startAnalysis()
        #expect(vm.state == .analyzing, "启动分析后立即进入分析中状态")
        #expect(!vm.canPickDirectories, "分析中不可选取目录")
        #expect(!vm.canStartAnalysis)

        let done = waitUntil { vm.state == .analyzed }
        #expect(done, "分析应在超时前完成")
        #expect(vm.result != nil)
        #expect(vm.progress == 1, "完成后进度收敛到 100%")
        #expect(!vm.phaseText.isEmpty)

        // 回调发生在注入的串行队列上
        let delivered = waitUntil { recorder.changeCount > 0 && !recorder.logLines.isEmpty }
        #expect(delivered, "委托回调应送达")
    }

    /// G4 路径缺失时 startAnalysis 不启动，仅记录日志
    @Test("G4 路径缺失不启动分析")
    func missingPathDoesNotStart() {
        let recorder = VMRecorder()
        let vm = makeViewModel(recorder: recorder)
        vm.primaryPath = nil

        vm.startAnalysis()
        #expect(vm.state == .idle, "缺路径不得进入分析中")
        let logged = waitUntil { !recorder.logLines.isEmpty }
        #expect(logged, "应记录提示日志")
    }

    /// G5 合并流程：分析 → 合并 → 回到空闲，最终目录写入主目录结构文件
    @Test("G5 合并流程与最终状态")
    func mergeFlow() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "sub/a.txt", content: "A")
        FMSupport.writeFile(root: secondaryRoot, relativePath: "b.txt", content: "B")

        let vm = makeViewModel()
        vm.startAnalysis()
        #expect(waitUntil { vm.state == .analyzed })
        #expect(vm.canStartMerge)

        vm.startMerge()
        #expect(vm.state == .merging, "合并中状态")
        #expect(!vm.canStartMerge, "合并中不可再次开始")

        let done = waitUntil { vm.state == .idle }
        #expect(done, "合并完成后回到空闲")
        #expect(vm.progress == 1)
        let mergedA = FileManager.default.fileExists(atPath: FMSupport.join(finalRoot, "sub/a.txt"))
        let mergedB = FileManager.default.fileExists(atPath: FMSupport.join(finalRoot, "b.txt"))
        #expect(mergedA, "主目录文件应按原结构写入最终目录")
        #expect(mergedB, "副目录独有文件应写入最终目录")
    }

    /// G6 合并后可重新开始新一轮分析（目录按钮恢复可用）
    @Test("G6 合并后回到可操作状态")
    func afterMergeCanPickAgain() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        let vm = makeViewModel()
        vm.startAnalysis()
        #expect(waitUntil { vm.state == .analyzed })
        vm.startMerge()
        #expect(waitUntil { vm.state == .idle })
        #expect(vm.canPickDirectories, "空闲后目录按钮恢复可用")
        #expect(vm.canStartAnalysis, "空闲后可再次分析")
    }

    /// G7 主目录不可读 → 分析失败、记录错误日志、状态回到空闲
    @Test("G7 分析失败回退到空闲")
    func analysisFailureFallsBackToIdle() {
        let locked = FMSupport.join(primaryRoot, "locked")
        try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        FMSupport.writeFile(root: locked, relativePath: "x.txt", content: "x")
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }

        let recorder = VMRecorder()
        let vm = makeViewModel(recorder: recorder)
        vm.primaryPath = locked

        vm.startAnalysis()
        #expect(vm.state == .analyzing)

        let done = waitUntil { vm.state == .idle }
        #expect(done, "失败后回到空闲")
        let hasError = waitUntil {
            recorder.logLines.contains { $0.contains("失败") || $0.contains("错误") || $0.contains("不可读") }
        }
        #expect(hasError, "应记录错误日志")
    }

    /// G8 空闲时调用 cancel 为无操作（不改变状态、不产生日志）
    @Test("G8 空闲时取消为无操作")
    func cancelWhenIdleIsNoop() {
        let recorder = VMRecorder()
        let vm = makeViewModel(recorder: recorder)

        vm.cancel()
        #expect(vm.state == .idle)
        #expect(vm.canPickDirectories)
        #expect(vm.canStartMerge == false)
    }

    /// G9 已分析状态下可重新选取目录；resetAnalysis 使结果失效并回到空闲
    @Test("G9 更换目录使分析结果失效")
    func resetAnalysisInvalidatesResult() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "A")
        let vm = makeViewModel()
        vm.startAnalysis()
        #expect(waitUntil { vm.state == .analyzed })
        #expect(vm.result != nil)
        #expect(vm.canPickDirectories, "已分析状态下允许重新选取目录")

        vm.resetAnalysis()
        #expect(vm.state == .idle, "失效后回到空闲")
        #expect(vm.result == nil, "分析结果被清除")
        #expect(vm.progress == 0)
        #expect(!vm.canStartMerge, "旧结果不可再用于合并")
        #expect(vm.canStartAnalysis, "可立即重新分析")

        // 其余状态下 resetAnalysis 为无操作
        vm.resetAnalysis()
        #expect(vm.state == .idle)
    }

    /// G10 更换目录后重新分析 → 合并遵循新目录内容（旧结果不残留）
    @Test("G10 失效后重新分析的结果正确")
    func reanalysisAfterResetUsesNewContent() throws {
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "OLD-A")
        let vm = makeViewModel()
        vm.startAnalysis()
        #expect(waitUntil { vm.state == .analyzed })

        // 模拟用户改动了主目录内容并重新选择目录（触发 resetAnalysis）
        FMSupport.writeFile(root: primaryRoot, relativePath: "a.txt", content: "NEW-A")
        FMSupport.writeFile(root: primaryRoot, relativePath: "b.txt", content: "B")
        vm.resetAnalysis()
        #expect(vm.state == .idle)

        vm.startAnalysis()
        #expect(waitUntil { vm.state == .analyzed })
        let result = vm.result
        #expect(result != nil)
        #expect(result?.uniquePrimary.count == 2, "新分析应包含改后的两个文件")
    }
}

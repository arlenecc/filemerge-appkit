import Testing
import Foundation
import FileMergeCore

/// D. FMProgressReporter 进度测试用例（D1–D3）
final class ProgressReporterTests {

    /// D1 总量只增不减，进度值单调不减（含总量扩展导致的回落被钳制）
    @Test("D1 总量只增不减且进度单调")
    func totalOnlyGrowsAndFractionMonotonic() {
        var fractions: [Double] = []
        let reporter = FMProgressReporter(interval: 0) { fraction, _, _ in
            fractions.append(fraction)
        }

        reporter.expandTotal(by:10)
        for _ in 0 ..< 5 { reporter.incrementCompleted() }
        reporter.finish()

        // 回调序列单调不减
        for (prev, cur) in zip(fractions, fractions.dropFirst()) {
            #expect(cur >= prev, "进度出现回跳: \(prev) -> \(cur)")
        }
        #expect(fractions.last == 1.0)
        #expect(reporter.currentFraction() == 1.0)
    }

    /// D1 附加：总量扩展后原始比例可能下降，但对外回调不回跳
    @Test("D1-2 扩展总量时对外进度不回跳")
    func expansionDoesNotRegressEmittedFraction() {
        var fractions: [Double] = []
        let reporter = FMProgressReporter(interval: 0) { fraction, _, _ in
            fractions.append(fraction)
        }

        reporter.expandTotal(by:10)
        for _ in 0 ..< 5 { reporter.incrementCompleted() }   // 5/10 = 0.5
        let midFraction = reporter.currentFraction()
        reporter.expandTotal(by:10)                           // 总量 20，原始比例降到 0.25
        for _ in 0 ..< 4 { reporter.incrementCompleted() }   // 9/20 = 0.45

        #expect(midFraction == 0.5)
        for (prev, cur) in zip(fractions, fractions.dropFirst()) {
            #expect(cur >= prev, "进度出现回跳: \(prev) -> \(cur)")
        }
        let after = reporter.currentFraction()
        #expect(after >= 0.45)
        reporter.finish()
        #expect(fractions.last == 1.0)
    }

    /// D2 回调节流：高频增量更新下回调次数远小于更新次数
    @Test("D2 100ms 节流防回调风暴")
    func throttlingBoundsCallbackCount() {
        let lock = NSLock()
        var callbacks = 0
        var lastFraction = 0.0
        let reporter = FMProgressReporter(interval: 0.1) { fraction, _, _ in
            lock.lock()
            callbacks += 1
            lastFraction = fraction
            lock.unlock()
        }

        reporter.expandTotal(by:1000)
        for _ in 0 ..< 1000 { reporter.incrementCompleted() }
        reporter.finish()

        lock.lock()
        defer { lock.unlock() }
        #expect(callbacks >= 1)
        #expect(callbacks <= 20, "1000 次增量更新不应产生超过 20 次回调，实际 \(callbacks)")
        #expect(lastFraction == 1.0)
    }

    /// D3 finish 强制收敛到 100%
    @Test("D3 finish 收敛到 100%")
    func finishReaches100Percent() {
        var lastFraction = 0.0
        var lastCompleted: UInt = 0
        var lastTotal: UInt = 0
        let reporter = FMProgressReporter(interval: 0) { fraction, completed, total in
            lastFraction = fraction
            lastCompleted = completed
            lastTotal = total
        }

        reporter.expandTotal(by:4)
        for _ in 0 ..< 2 { reporter.incrementCompleted() }
        reporter.finish()

        #expect(lastFraction == 1.0)
        #expect(lastCompleted == 4)
        #expect(lastTotal == 4)
        #expect(reporter.currentFraction() == 1.0)
    }

    /// D3 附加：零工作量 finish 也视为 100%
    @Test("D3-2 零工作量 finish 为 100%")
    func finishWithZeroTotal() {
        var lastFraction: Double?
        let reporter = FMProgressReporter(interval: 0) { fraction, _, _ in
            lastFraction = fraction
        }
        reporter.finish()
        #expect(lastFraction == 1.0)
    }
}

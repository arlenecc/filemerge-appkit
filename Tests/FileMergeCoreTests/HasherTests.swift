import Testing
import Foundation
import FileMergeCore

/// B. FMFileHasher 哈希测试用例（B1–B4）
final class HasherTests {
    let root = FMSupport.makeTemporaryDirectory("hash")
    let hasher = FMFileHasher()

    deinit { FMSupport.removeTree(root) }

    /// B1 同内容不同路径 → 相同哈希；不同内容 → 不同哈希
    @Test("B1 同内容同哈希/异内容异哈希")
    func hashDeterminism() throws {
        let a = FMSupport.writeFile(root: root, relativePath: "a.txt", content: "hello world")
        let b = FMSupport.writeFile(root: root, relativePath: "sub/b.txt", content: "hello world")
        let c = FMSupport.writeFile(root: root, relativePath: "c.txt", content: "goodbye world")

        let recA = try #require(FMSupport.record(root: root, relativePath: "a.txt", origin: .primary))
        let recB = try #require(FMSupport.record(root: root, relativePath: "sub/b.txt", origin: .primary))
        let recC = try #require(FMSupport.record(root: root, relativePath: "c.txt", origin: .primary))
        #expect(a != b && b != c)

        let hashA1 = try #require(try hasher.fullHash(forFile: recA))
        let hashA2 = try #require(try hasher.fullHash(forFile: recA))
        let hashB = try #require(try hasher.fullHash(forFile: recB))
        let hashC = try #require(try hasher.fullHash(forFile: recC))

        #expect(hashA1 == hashA2)  // 同文件结果稳定
        #expect(hashA1 == hashB)   // 同内容不同路径
        #expect(hashA1 != hashC)   // 不同内容
        #expect(hashA1.count == 32)  // SHA256 摘要长度
    }

    /// B2 >64KB 头部相同、尾部不同的大文件仍可区分（全量 SHA256 兜底）
    @Test("B2 头部相同尾部不同的大文件可区分")
    func bigFilesWithSameHeadDistinguished() throws {
        let size = 128 * 1024
        let pathA = FMSupport.writeData(root: root, relativePath: "bigA.bin", bytes: size, offset: 0)
        let pathB = FMSupport.writeData(root: root, relativePath: "bigB.bin", bytes: size, offset: 0)
        // 让 B 的尾部（第 70KB 处）与 A 不同，前 64KB 保持一致
        FMSupport.flipByte(pathB, offset: 70 * 1024, to: 0xAB)

        let recA = try #require(FMSupport.record(root: root, relativePath: "bigA.bin", origin: .primary))
        let recB = try #require(FMSupport.record(root: root, relativePath: "bigB.bin", origin: .primary))

        let headA = try #require(try hasher.headHash(forFile: recA))
        let headB = try #require(try hasher.headHash(forFile: recB))
        #expect(headA == headB, "前 64KB 相同则头部哈希相同")

        let fullA = try #require(try hasher.fullHash(forFile: recA))
        let fullB = try #require(try hasher.fullHash(forFile: recB))
        #expect(fullA != fullB, "全量哈希必须区分尾部差异")
    }

    /// B3 头部哈希只算头部，全量哈希按需计算
    @Test("B3 头部哈希与全量哈希分别计数")
    func headHashDoesNotComputeFull() throws {
        FMSupport.writeData(root: root, relativePath: "big.bin", bytes: 100 * 1024, offset: 1)
        let rec = try #require(FMSupport.record(root: root, relativePath: "big.bin", origin: .primary))

        _ = try #require(try hasher.headHash(forFile: rec))
        #expect(hasher.headHashComputations == 1)
        #expect(hasher.fullHashComputations == 0, "仅请求头部哈希时不应触发全量计算")

        _ = try #require(try hasher.fullHash(forFile: rec))
        #expect(hasher.fullHashComputations == 1)
    }

    /// B4 同一文件重复哈希命中缓存，不重复计算
    @Test("B4 重复哈希命中缓存")
    func repeatedHashHitsCache() throws {
        FMSupport.writeFile(root: root, relativePath: "cached.txt", content: "payload")
        let rec = try #require(FMSupport.record(root: root, relativePath: "cached.txt", origin: .primary))

        _ = try #require(try hasher.headHash(forFile: rec))
        _ = try #require(try hasher.headHash(forFile: rec))
        _ = try #require(try hasher.fullHash(forFile: rec))
        _ = try #require(try hasher.fullHash(forFile: rec))

        #expect(hasher.headHashComputations == 1)
        #expect(hasher.fullHashComputations == 1)
    }
}

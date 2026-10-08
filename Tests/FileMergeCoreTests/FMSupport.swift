import Foundation
import Darwin
import FileMergeCore

/// 测试支撑：临时目录与样例文件构造
enum FMSupport {
    static func makeTemporaryDirectory(_ prefix: String) -> String {
        let name = "\(prefix)-\(UUID().uuidString)-fmtest"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // 规范化为 realpath（/var → /private/var 等），与生产代码 realpath 解析表示一致
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil, let resolved = String(validatingUTF8: buf) {
            return resolved
        }
        return path
    }

    static func join(_ root: String, _ relativePath: String) -> String {
        (root as NSString).appendingPathComponent(relativePath)
    }

    @discardableResult
    static func writeFile(root: String, relativePath: String, content: String) -> String {
        let path = join(root, relativePath)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// 写入指定字节数的文件，内容从 offset 起递增，保证不同 offset 的文件内容可区分
    @discardableResult
    static func writeData(root: String, relativePath: String, bytes: Int, offset: UInt8) -> String {
        let path = join(root, relativePath)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var data = Data(capacity: bytes)
        for i in 0 ..< bytes {
            data.append(offset &+ UInt8(truncatingIfNeeded: i))
        }
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func record(root: String, relativePath: String, origin: FMFileOrigin) -> FMFileRecord? {
        let path = join(root, relativePath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return FMFileRecord(origin: origin, rootPath: root, relativePath: relativePath, absolutePath: path, fileSize: size)
    }

    static func removeTree(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 修改文件内指定偏移处的一个字节（构造"头部相同、尾部不同"的样例）
    static func flipByte(_ path: String, offset: Int, to value: UInt8) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        if #available(macOS 10.15.4, *) {
            try? handle.seek(toOffset: UInt64(offset))
        } else {
            handle.seek(toFileOffset: UInt64(offset))
        }
        _ = try? handle.write(contentsOf: Data([value]))
    }
}

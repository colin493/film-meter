import Foundation
import UIKit

enum Store {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var compositionsDir: URL { docs.appendingPathComponent("Compositions", isDirectory: true) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = docs.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: docs.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Compositions

    private static func folder(_ id: UUID) -> URL { compositionsDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumb.jpg") }

    static func saveComposition(_ frame: LockedFrame, preview: CGImage?) throws {
        let dir = folder(frame.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(frame.meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        // Linear light as half floats (RGB).
        let n = frame.width * frame.height
        var rgb = [Float](repeating: 0, count: n * 3)
        for i in 0..<n { rgb[i * 3] = frame.linear[i * 4]; rgb[i * 3 + 1] = frame.linear[i * 4 + 1]; rgb[i * 3 + 2] = frame.linear[i * 4 + 2] }
        try packHalf(rgb).write(to: dir.appendingPathComponent("linear.bin"), options: .atomic)
        if let d = frame.depth {
            try d.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("depth.bin"), options: .atomic)
        }
        if let preview, let jpg = UIImage(cgImage: preview).jpegData(compressionQuality: 0.8) {
            try jpg.write(to: dir.appendingPathComponent("thumb.jpg"), options: .atomic)
        }
    }

    static func listCompositions() -> [CompositionMeta] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: compositionsDir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(CompositionMeta.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    static func loadComposition(_ meta: CompositionMeta) -> LockedFrame? {
        let dir = folder(meta.id)
        guard let lin = try? Data(contentsOf: dir.appendingPathComponent("linear.bin")) else { return nil }
        let rgb = unpackHalf(lin)
        let n = meta.width * meta.height
        guard rgb.count >= n * 3 else { return nil }
        var linear = [Float](repeating: 1, count: n * 4)
        for i in 0..<n { linear[i * 4] = rgb[i * 3]; linear[i * 4 + 1] = rgb[i * 3 + 1]; linear[i * 4 + 2] = rgb[i * 3 + 2] }
        var depth: [Float]?
        if meta.depthWidth > 0, let d = try? Data(contentsOf: dir.appendingPathComponent("depth.bin")), d.count >= meta.depthWidth * meta.depthHeight * 4 {
            var arr = [Float](repeating: 0, count: meta.depthWidth * meta.depthHeight)
            _ = arr.withUnsafeMutableBytes { d.copyBytes(to: $0) }
            depth = arr
        }
        return LockedFrame(meta: meta, width: meta.width, height: meta.height, linear: linear, depth: depth)
    }

    static func deleteComposition(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    private static func packHalf(_ v: [Float]) -> Data {
        #if arch(arm64)
        let h = v.map { Float16($0) }
        return h.withUnsafeBufferPointer { Data(buffer: $0) }
        #else
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
        #endif
    }

    private static func unpackHalf(_ d: Data) -> [Float] {
        #if arch(arm64)
        var h = [Float16](repeating: 0, count: d.count / 2)
        _ = h.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return h.map { Float($0) }
        #else
        var f = [Float](repeating: 0, count: d.count / 4)
        _ = f.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return f
        #endif
    }
}

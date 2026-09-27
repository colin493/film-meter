import Foundation
import simd

/// Colin's look, fitted to his 2025–26 Negative Lab Pro conversions.
/// Colour: 3D table from per-frame normalised negative density to Display P3 (sRGB curve).
/// B&W: 1D curve from normalised density to grey.
final class LookTables {
    static let shared = LookTables()

    private(set) var size: Int = 0
    private var base: [Float] = []      // N^3 * 3, r fastest
    private(set) var table: [Float] = []
    private(set) var bw: [Float] = []
    private(set) var greensShift: Float = 0
    private let lock = NSLock()

    private init() {
        if let url = Bundle.main.url(forResource: "ColinLook", withExtension: "bin"), let data = try? Data(contentsOf: url), data.count > 4 {
            let n = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
            let count = n * n * n * 3
            if data.count >= 4 + count * 4 {
                var vals = [Float](repeating: 0, count: count)
                _ = vals.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: 4..<(4 + count * 4)) }
                size = n; base = vals; table = vals
            }
        }
        if let url = Bundle.main.url(forResource: "ColinBW", withExtension: "bin"), let data = try? Data(contentsOf: url), data.count > 4 {
            let n = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
            if data.count >= 4 + n * 4 {
                var vals = [Float](repeating: 0, count: n)
                _ = vals.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: 4..<(4 + n * 4)) }
                bw = vals
            }
        }
        if size == 0 {  // fallback: plain display of the normalised density
            size = 2
            base = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1]
            table = base
        }
        if bw.isEmpty { bw = (0..<256).map { Float($0) / 255 } }
    }

    var isLoaded: Bool { size > 2 }

    func setGreensShift(_ degrees: Float) {
        lock.lock(); defer { lock.unlock() }
        guard degrees != greensShift else { return }
        greensShift = degrees
        if degrees == 0 { table = base; return }
        var t = base
        let count = size * size * size
        for i in 0..<count {
            let c = SIMD3<Float>(base[i * 3], base[i * 3 + 1], base[i * 3 + 2])
            let o = ColorMath.shiftGreens(p3Encoded: c, degrees: degrees)
            t[i * 3] = o.x; t[i * 3 + 1] = o.y; t[i * 3 + 2] = o.z
        }
        table = t
    }

    func snapshot() -> (size: Int, table: [Float], bw: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (size, table, bw)
    }

    /// Trilinear lookup, q in 0...1 per channel.
    @inline(__always)
    static func sample(_ table: UnsafePointer<Float>, size n: Int, _ q: SIMD3<Float>) -> SIMD3<Float> {
        let m = Float(n - 1)
        let p = simd_clamp(q, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * m
        let i0 = SIMD3<Int>(Int(min(p.x, m - 0.0001)), Int(min(p.y, m - 0.0001)), Int(min(p.z, m - 0.0001)))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        @inline(__always) func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let idx = ((b * n + g) * n + r) * 3
            return SIMD3(table[idx], table[idx + 1], table[idx + 2])
        }
        let c000 = at(i0.x, i0.y, i0.z), c100 = at(i0.x + 1, i0.y, i0.z)
        let c010 = at(i0.x, i0.y + 1, i0.z), c110 = at(i0.x + 1, i0.y + 1, i0.z)
        let c001 = at(i0.x, i0.y, i0.z + 1), c101 = at(i0.x + 1, i0.y, i0.z + 1)
        let c011 = at(i0.x, i0.y + 1, i0.z + 1), c111 = at(i0.x + 1, i0.y + 1, i0.z + 1)
        let c00 = c000 + (c100 - c000) * f.x, c10 = c010 + (c110 - c010) * f.x
        let c01 = c001 + (c101 - c001) * f.x, c11 = c011 + (c111 - c011) * f.x
        let c0 = c00 + (c10 - c00) * f.y, c1 = c01 + (c11 - c01) * f.y
        return c0 + (c1 - c0) * f.z
    }

    @inline(__always)
    static func sampleBW(_ curve: UnsafePointer<Float>, count: Int, _ p: Float) -> Float {
        let x = max(0, min(1, p)) * Float(count - 1)
        let i = min(count - 2, Int(x))
        let t = x - Float(i)
        return curve[i] + (curve[i + 1] - curve[i]) * t
    }
}

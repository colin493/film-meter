import Foundation
import simd

/// Everything needed to turn scene exposure into a finished-looking film render.
struct FilmLook: Equatable {
    enum Mode: Equatable { case neutral, colorNegative, bwNegative, slide }

    var mode: Mode = .neutral
    var shadowLimit: Float = -3
    var highlightLimit: Float = 8
    var saturation: Float = 1
    var contrast: Float = 1
    var warmth: Float = 0
    var tint: Float = 0
    var bwWeights = SIMD3<Float>(0.3, 0.56, 0.14)
    var gains = SIMD3<Float>(1, 1, 1)        // filter colour, luminance-normalised
    var houseLook = true
    /// Per-channel exposure percentiles of the frame (stops re: 18% grey, before `k`), used for NLP-style levelling.
    var lo = SIMD3<Float>(-4, -4, -4)
    var hi = SIMD3<Float>(3, 3, 3)
    /// Stops added to every pixel's exposure: phone exposure vs. where the film's middle grey is placed.
    var k: Float = 0

    static func make(stock: FilmStock?, pushStops: Double, filters: [FilterDef], houseLook: Bool) -> FilmLook {
        var look = FilmLook()
        look.houseLook = houseLook
        look.gains = colourGains(filters)
        guard let s = stock else { look.mode = .neutral; return look }
        switch s.kind {
        case .colorNegative: look.mode = .colorNegative
        case .bwNegative: look.mode = .bwNegative
        case .slide: look.mode = .slide
        }
        let push = Float(pushStops)
        let isNeg = s.kind != .slide
        look.shadowLimit = Float(s.shadowLimit) + (isNeg ? 0.7 * push : push)
        look.highlightLimit = Float(s.highlightLimit) - (isNeg ? 0.5 * push : push)
        look.saturation = Float(s.saturation)
        look.contrast = Float(s.contrast) * (1 + 0.08 * push)
        look.warmth = Float(s.warmth)
        look.tint = Float(s.tint)
        if s.bwWeights.count == 3 {
            let w = SIMD3<Float>(Float(s.bwWeights[0]), Float(s.bwWeights[1]), Float(s.bwWeights[2]))
            look.bwWeights = w / max(0.001, w.x + w.y + w.z)
        }
        return look
    }

    /// Product of filter transmissions, normalised so a grey card keeps its brightness
    /// (the filter factor is already taken care of by the exposure).
    static func colourGains(_ filters: [FilterDef]) -> SIMD3<Float> {
        var g = SIMD3<Float>(1, 1, 1)
        for f in filters where f.transmission.count == 3 {
            g *= SIMD3<Float>(Float(f.transmission[0]), Float(f.transmission[1]), Float(f.transmission[2]))
        }
        let y = ColorMath.luminance(g)
        return y > 0 ? g / y : SIMD3(1, 1, 1)
    }
}

/// Per-frame constants derived from a look, so the per-pixel path stays cheap.
struct PreparedLook {
    let look: FilmLook
    let dlo: SIMD3<Float>
    let dhi: SIMD3<Float>
    let dloBW: Float
    let dhiBW: Float

    init(_ look: FilmLook) {
        self.look = look
        let s = look.shadowLimit, h = look.highlightLimit
        let lo = look.lo + look.k, hi = look.hi + look.k
        dlo = SIMD3<Float>(FilmPipeline.density(lo.x, s: s, h: h), FilmPipeline.density(lo.y, s: s, h: h), FilmPipeline.density(lo.z, s: s, h: h))
        dhi = SIMD3<Float>(FilmPipeline.density(hi.x, s: s, h: h), FilmPipeline.density(hi.y, s: s, h: h), FilmPipeline.density(hi.z, s: s, h: h))
        dloBW = dlo.x
        dhiBW = dhi.x
    }
}

enum FilmPipeline {
    @inline(__always) static func softplus(_ x: Float) -> Float {
        if x > 20 { return x }
        if x < -20 { return 0 }
        return log1pf(expf(x))
    }

    /// Film response in stops: straight line with a soft toe below `s` and a soft shoulder above `h`.
    @inline(__always) static func density(_ e: Float, s: Float, h: Float) -> Float {
        let k: Float = 0.45
        let t = s + k * softplus((e - s) / k)
        return h - k * softplus((h - t) / k)
    }

    /// Render one pixel. `e` is exposure in stops relative to the film's middle grey, per channel,
    /// already including filter colour and `k`.
    @inline(__always)
    static func render(e: SIMD3<Float>, prep: PreparedLook, table: UnsafePointer<Float>, size: Int,
                       bw: UnsafePointer<Float>, bwCount: Int) -> SIMD3<Float> {
        let look = prep.look
        switch look.mode {
        case .neutral:
            let lin = 0.18 * SIMD3<Float>(exp2f(e.x), exp2f(e.y), exp2f(e.z))
            let p3 = ColorMath.sRGBToP3 * lin
            return SIMD3(ColorMath.srgbEncode(min(1, p3.x)), ColorMath.srgbEncode(min(1, p3.y)), ColorMath.srgbEncode(min(1, p3.z)))

        case .colorNegative:
            let s = look.shadowLimit, h = look.highlightLimit
            let d = SIMD3<Float>(density(e.x, s: s, h: h), density(e.y, s: s, h: h), density(e.z, s: s, h: h))
            var p = (d - prep.dlo) / simd_max(prep.dhi - prep.dlo, SIMD3<Float>(repeating: 0.25))
            let m = (p.x + p.y + p.z) / 3
            p = m + (p - m) * look.saturation
            p = 0.5 + (p - 0.5) * look.contrast
            p.x += look.warmth * 0.03 + look.tint * 0.015
            p.y -= look.tint * 0.03
            p.z -= look.warmth * 0.03
            if look.houseLook {
                return LookTables.sample(table, size: size, (p + 0.15) / 1.3)
            }
            return simd_clamp(p, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

        case .bwNegative:
            let s = look.shadowLimit, h = look.highlightLimit
            let lin = SIMD3<Float>(exp2f(e.x), exp2f(e.y), exp2f(e.z))
            let ey = log2f(max(1e-6, simd_dot(look.bwWeights, lin)))
            var p = (density(ey, s: s, h: h) - prep.dloBW) / max(0.25, prep.dhiBW - prep.dloBW)
            p = 0.5 + (p - 0.5) * look.contrast
            let g = look.houseLook ? LookTables.sampleBW(bw, count: bwCount, p) : max(0, min(1, p))
            return SIMD3(repeating: g)

        case .slide:
            let s = look.shadowLimit, h = look.highlightLimit
            let d = SIMD3<Float>(density(e.x, s: s, h: h), density(e.y, s: s, h: h), density(e.z, s: s, h: h))
            let a = s - 0.3, b = h + 0.3
            var p = (d - a) / (b - a)
            // Reversal S-curve
            let c = 4.0 * look.contrast
            p = SIMD3<Float>(1 / (1 + expf(-c * (p.x - 0.5))), 1 / (1 + expf(-c * (p.y - 0.5))), 1 / (1 + expf(-c * (p.z - 0.5))))
            let lo0 = 1 / (1 + expf(c * 0.5)), hi0 = 1 / (1 + expf(-c * 0.5))
            p = (p - lo0) / (hi0 - lo0)
            let y = ColorMath.luminance(p)
            p = y + (p - y) * look.saturation
            p.x += look.warmth * 0.02 + look.tint * 0.01
            p.y -= look.tint * 0.02
            p.z -= look.warmth * 0.02
            return simd_clamp(p, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        }
    }

    enum CubeInput { case videoSRGB, logEncoded }

    /// Log encoding used for stills: 16 stops centred on middle grey.
    @inline(__always) static func logEncode(_ x: Float) -> Float { max(0, min(1, (log2f(max(x, 1e-7) / 0.18) + 8) / 16)) }

    /// Composite 3D LUT (RGBA float, r fastest) for Core Image's CIColorCube.
    static func buildCube(size n: Int, input: CubeInput, look: FilmLook) -> Data {
        let snap = LookTables.shared.snapshot()
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let gl = SIMD3<Float>(log2f(look.gains.x), log2f(look.gains.y), log2f(look.gains.z))
        let inv = 1 / Float(n - 1)
        let prep = PreparedLook(look)
        snap.table.withUnsafeBufferPointer { tp in
            snap.bw.withUnsafeBufferPointer { bp in
                guard let t = tp.baseAddress, let b = bp.baseAddress else { return }
                for bi in 0..<n {
                    for gi in 0..<n {
                        for ri in 0..<n {
                            let v = SIMD3<Float>(Float(ri), Float(gi), Float(bi)) * inv
                            var e: SIMD3<Float>
                            switch input {
                            case .videoSRGB:
                                let l = SIMD3<Float>(ColorMath.srgbDecode(v.x), ColorMath.srgbDecode(v.y), ColorMath.srgbDecode(v.z))
                                e = SIMD3<Float>(log2f(max(l.x, 1e-5) / 0.18), log2f(max(l.y, 1e-5) / 0.18), log2f(max(l.z, 1e-5) / 0.18)) + gl
                            case .logEncoded:
                                e = v * 16 - 8
                            }
                            e += look.k
                            let c = render(e: e, prep: prep, table: t, size: snap.size, bw: b, bwCount: snap.bw.count)
                            let idx = ((bi * n + gi) * n + ri) * 4
                            out[idx] = c.x; out[idx + 1] = c.y; out[idx + 2] = c.z; out[idx + 3] = 1
                        }
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

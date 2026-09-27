import Foundation
import simd

enum ColorMath {
    @inline(__always) static func srgbDecode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func srgbEncode(_ v: Float) -> Float {
        let c = max(0, v)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    static let p3ToSRGB = simd_float3x3(rows: [SIMD3<Float>(1.224745, -0.2249043, 0),
                                               SIMD3<Float>(-0.0420578, 1.042081, 0),
                                               SIMD3<Float>(-0.0196423, -0.0786549, 1.0985372)])
    static let sRGBToP3 = simd_float3x3(rows: [SIMD3<Float>(0.822593, 0.1775339, 0),
                                               SIMD3<Float>(0.0331994, 0.9667835, 0),
                                               SIMD3<Float>(0.0170854, 0.0723957, 0.9103014)])

    static func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    // OKLab (Björn Ottosson), on linear sRGB.
    static func oklab(fromLinearSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s)
        return SIMD3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                     1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                     0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    static func linearSRGB(fromOklab lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Rotate yellow-green hues (OKLab hue 98°–152°) by `degrees`, weighted so neutrals and yellows stay put.
    static func shiftGreens(p3Encoded c: SIMD3<Float>, degrees: Float) -> SIMD3<Float> {
        if degrees == 0 { return c }
        let lin = SIMD3<Float>(srgbDecode(c.x), srgbDecode(c.y), srgbDecode(c.z))
        let lab = oklab(fromLinearSRGB: p3ToSRGB * lin)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h = atan2f(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        let lo: Float = 98, hi: Float = 152
        guard h > lo && h < hi else { return c }
        var w = 0.5 - 0.5 * cosf(2 * .pi * (h - lo) / (hi - lo))
        w *= min(1, chroma / 0.03)
        let nh = (h + degrees * w) * .pi / 180
        let out = sRGBToP3 * linearSRGB(fromOklab: SIMD3(lab.x, chroma * cosf(nh), chroma * sinf(nh)))
        return SIMD3(srgbEncode(min(1, out.x)), srgbEncode(min(1, out.y)), srgbEncode(min(1, out.z)))
    }
}

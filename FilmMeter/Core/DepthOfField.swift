import Foundation

enum DepthOfField {
    /// Blur-circle diameter on film (mm) for an object at `objectM` when focused at `focusM`.
    static func blurDiameterMM(focalMM f: Double, aperture n: Double, focusM: Double, objectM: Double) -> Double {
        let s1 = max(focusM * 1000, f * 1.01)
        let s2 = objectM.isFinite ? max(objectM * 1000, f * 1.01) : 1e12
        return abs(s2 - s1) / s2 * f * f / (n * (s1 - f))
    }

    static func hyperfocalM(focalMM f: Double, aperture n: Double, cocMM c: Double) -> Double {
        (f * f / (n * c) + f) / 1000
    }

    /// Near and far limits of acceptable sharpness in metres (far may be infinity).
    static func limits(focalMM f: Double, aperture n: Double, cocMM c: Double, focusM: Double) -> (near: Double, far: Double) {
        let h = hyperfocalM(focalMM: f, aperture: n, cocMM: c) * 1000
        let s = focusM * 1000
        let near = s * (h - f) / (h + s - 2 * f)
        let far = s < h ? s * (h - f) / (h - s) : Double.infinity
        return (near / 1000, far.isFinite ? far / 1000 : .infinity)
    }
}

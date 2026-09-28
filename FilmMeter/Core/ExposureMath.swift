import Foundation

enum ExposureMode: String, Codable, CaseIterable, Identifiable {
    case manual = "M", aperturePriority = "Av", shutterPriority = "Tv"
    var id: String { rawValue }
}

enum MeteringMode: String, Codable, CaseIterable, Identifiable {
    case subject = "Subject", matrix = "Matrix"
    var id: String { rawValue }
}

enum ExposureMath {
    static let fullApertures: [Double] = [1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22, 32, 45, 64]
    static let halfApertures: [Double] = [1.0, 1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.3, 4.0, 4.8, 5.6, 6.7, 8.0, 9.5, 11, 13, 16, 19, 22, 27, 32, 38, 45, 54, 64]
    static let thirdApertures: [Double] = [1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32, 36, 40, 45, 51, 57, 64]

    static let fullShutters: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60,
                                         1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1, 2, 4, 8, 15, 30, 60]
    static let thirdShutters: [Double] = [1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200, 1.0 / 2500, 1.0 / 2000, 1.0 / 1600,
                                          1.0 / 1250, 1.0 / 1000, 1.0 / 800, 1.0 / 640, 1.0 / 500, 1.0 / 400, 1.0 / 320, 1.0 / 250,
                                          1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100, 1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 40, 1.0 / 30,
                                          1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10, 1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 0.3, 0.4,
                                          0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]

    /// Exposure value at ISO 100 for a camera setting.
    static func ev100(aperture n: Double, shutter t: Double, iso: Double) -> Double {
        log2(n * n / t) - log2(iso / 100)
    }

    /// Shutter time giving `ev` (at the film's speed) for aperture `n`.
    static func shutter(forEV ev: Double, aperture n: Double) -> Double { n * n / pow(2, ev) }

    /// Aperture giving `ev` for shutter `t`.
    static func aperture(forEV ev: Double, shutter t: Double) -> Double { (t * pow(2, ev)).squareRoot() }

    static func nearest(_ value: Double, in list: [Double]) -> Double {
        guard !list.isEmpty else { return value }
        return list.min { abs(log2($0 / value)) < abs(log2($1 / value)) } ?? value
    }

    static func formatAperture(_ n: Double) -> String {
        if n >= 10 { return String(format: "%.0f", n) }
        let r = (n * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    static func formatShutter(_ t: Double) -> String {
        if t >= 0.95 {
            if t >= 60 {
                let m = Int(t / 60), s = Int(t.rounded()) % 60
                return s == 0 ? "\(m)m" : "\(m)m \(s)s"
            }
            return t < 10 ? String(format: "%.1fs", t).replacingOccurrences(of: ".0s", with: "s") : "\(Int(t.rounded()))s"
        }
        if t >= 0.29 {
            return String(format: "%.1fs", t)
        }
        let nice = nearest(1 / t, in: displayDenominators)
        return "1/\(Int(nice))"
    }

    static let displayDenominators: [Double] = [2, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250,
                                                 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6000, 6400, 8000]

    /// "+⅔", "−1⅓", "0" style labels for thirds of a stop.
    static func formatStops(_ s: Double, signed: Bool = true) -> String {
        let thirds = Int((s * 3).rounded())
        if thirds == 0 { return "0" }
        let sign = thirds > 0 ? (signed ? "+" : "") : "−"
        let a = abs(thirds)
        let whole = a / 3, frac = a % 3
        let fracStr = frac == 1 ? "⅓" : (frac == 2 ? "⅔" : "")
        if whole == 0 { return sign + fracStr }
        return sign + "\(whole)" + fracStr
    }

    static func formatEV(_ ev: Double) -> String {
        let v = (ev * 10).rounded() / 10
        return String(format: "EV %.1f", v == 0 ? 0 : v)   // never "EV -0.0"
    }

    /// Nearest standard third-stop shutter speed, for times that should read like a camera's dial.
    static func nominalShutter(_ t: Double) -> Double {
        guard let last = thirdShutters.last, t <= last * 1.12 else { return t }
        return nearest(t, in: thirdShutters)
    }

    static func formatDistance(_ m: Double, feet: Bool) -> String {
        if !m.isFinite || m > 999 { return "∞" }
        if feet {
            let ft = m * 3.28084
            return ft < 10 ? String(format: "%.1f ft", ft) : String(format: "%.0f ft", ft)
        }
        return m < 10 ? String(format: "%.2f m", m) : String(format: "%.1f m", m)
    }
}

/// Everything the solver needs to turn a scene reading into camera settings.
struct ExposureInputs {
    var sceneEV100: Double          // metered EV100 of the placement (middle grey)
    var filmISO: Double             // box speed
    var pushStops: Double
    var filterStops: Double
    var compensation: Double        // user compensation, stops (+ = more exposure)
    var mode: ExposureMode
    var aperture: Double            // chosen or current aperture
    var shutter: Double             // chosen or current shutter
    var body: CameraBody
    var lens: Lens
    var reciprocity: ReciprocityRule?
}

struct ExposureReading: Equatable {
    var aperture: Double
    var shutter: Double              // metered shutter, snapped to the body
    var exactShutter: Double
    var exactAperture: Double
    var residual: Double             // stops the snapped setting is off (+ = overexposed)
    var targetEV: Double             // EV at the film's EI after filters and compensation
    var reciprocity: ReciprocityResult?
    var needle: Double               // manual mode: + means over metered
    var warnings: [String]
    var effectiveISO: Double
    var usesBulb: Bool
}

enum ExposureSolver {
    static func solve(_ i: ExposureInputs) -> ExposureReading {
        let ei = i.filmISO * pow(2, i.pushStops)
        // Target EV at the film's EI: less light reaches the film through filters, and compensation adds exposure.
        let target = i.sceneEV100 + log2(ei / 100) - i.filterStops - i.compensation
        let stops = i.lens.apertureStops
        let speeds = i.body.shutterSpeeds
        var warnings: [String] = []
        var n = i.aperture, t = i.shutter
        var exactT = t, exactN = n
        var usesBulb = false

        switch i.mode {
        case .aperturePriority:
            n = ExposureMath.nearest(i.aperture, in: stops)
            exactT = ExposureMath.shutter(forEV: target, aperture: n)
            exactN = n
            if exactT > i.body.slowestShutter * 1.03 {
                if i.body.hasBulb { usesBulb = true; t = exactT } else { t = i.body.slowestShutter; warnings.append("Slower than the camera's slowest speed") }
            } else {
                t = ExposureMath.nearest(exactT, in: speeds)
                if exactT < i.body.fastestShutter * 0.97 { warnings.append("Faster than the camera's top speed: stop down or add ND") }
            }
        case .shutterPriority:
            t = ExposureMath.nearest(i.shutter, in: speeds)
            exactT = t
            exactN = ExposureMath.aperture(forEV: target, shutter: t)
            n = ExposureMath.nearest(exactN, in: stops)
            if exactN < i.lens.maxAperture * 0.97 { warnings.append("Needs a wider aperture than f/\(ExposureMath.formatAperture(i.lens.maxAperture))") }
            if exactN > i.lens.minAperture * 1.03 { warnings.append("Needs more than f/\(ExposureMath.formatAperture(i.lens.minAperture)): use a faster shutter or ND") }
        case .manual:
            n = ExposureMath.nearest(i.aperture, in: stops)
            t = i.shutter > i.body.slowestShutter * 1.03 && i.body.hasBulb ? i.shutter : ExposureMath.nearest(i.shutter, in: speeds)
            usesBulb = t > i.body.slowestShutter * 1.03
            exactN = n; exactT = ExposureMath.shutter(forEV: target, aperture: n)
        }

        // Reciprocity: the time the film actually needs.
        var recip: ReciprocityResult? = nil
        if let rule = i.reciprocity {
            let base = i.mode == .manual ? exactT : max(t, exactT)
            let r = rule.correct(i.mode == .aperturePriority ? exactT : base)
            if r.needsCorrection || r.notRecommended { recip = r }
            if i.mode == .aperturePriority, r.needsCorrection {
                if r.corrected > i.body.slowestShutter * 1.03 {
                    if i.body.hasBulb { usesBulb = true; t = r.corrected } else { warnings.append("Corrected time exceeds the camera's slowest speed") }
                } else {
                    t = ExposureMath.nearest(r.corrected, in: speeds)
                }
            }
        }

        // Residual and needle: compare what the settings give with what the film needs.
        let actualT: Double
        if let rule = i.reciprocity { actualT = rule.effectiveTime(forActual: t) } else { actualT = t }
        let settingEV = log2(n * n / actualT)
        let residual = target - settingEV   // + means the setting gives more exposure than needed
        let needle = i.mode == .manual ? residual : 0
        return ExposureReading(aperture: n, shutter: t, exactShutter: exactT, exactAperture: exactN, residual: residual,
                               targetEV: target, reciprocity: recip, needle: needle, warnings: warnings,
                               effectiveISO: ei, usesBulb: usesBulb)
    }
}

import Foundation
import simd

struct MeterResult: Equatable {
    /// Scene EV at ISO 100 that should land on the film's middle grey.
    var placementEV: Double
    /// Plain average reading, for comparison.
    var averageEV: Double
    var reason: String
    /// Scene brightness range the phone saw (stops) and whether it clipped.
    var sceneRange: Double
    var phoneClipped: Bool
    var shadowsEV: Double
    var highlightsEV: Double
}

enum Meter {
    /// - Parameters:
    ///   - zone: for subject metering, stops above middle grey the subject should render (0 = Zone V).
    static func evaluate(stats: FrameStats, mode: MeteringMode, zone: Double, stock: FilmStock?, pushStops: Double,
                         calibration: Double, sun: SunPosition?, attitude: Attitude?, display: DisplayOrientation) -> MeterResult {
        let evPhone = stats.exposure.ev100 + calibration
        let average = evPhone + Double(stats.logAverage)
        let shadows = evPhone + Double(stats.p5)
        let highlights = evPhone + Double(stats.p995)
        let range = Double(stats.p995 - stats.p1)
        var placement: Double
        var reasons: [String] = []

        switch mode {
        case .subject:
            if let s = stats.subject {
                placement = evPhone + Double(s) - zone
                reasons.append(zone == 0 ? "Subject as middle grey" : "Subject placed \(ExposureMath.formatStops(zone)) from middle grey")
            } else {
                placement = evPhone + Double(stats.centerWeighted)
                reasons.append("Tap a subject to meter it")
            }

        case .matrix:
            let base = 0.6 * Double(stats.centerWeighted) + 0.4 * Double(stats.logAverage)
            placement = evPhone + base
            var offset = 0.0   // stops the scene average should sit above middle grey

            let backlitBySun: Bool = {
                guard let sun, let att = attitude, att.hasTrueNorth, sun.elevation > -2 else { return false }
                let fwd = simd_normalize(att.cameraForward)
                let ang = acos(max(-1, min(1, simd_dot(fwd, sun.worldVector)))) * 180 / .pi
                return ang < 55
            }()
            let contrasty = stats.p995 - stats.p50 > 3.2 && stats.centerWeighted < stats.logAverage - 0.3

            if let face = stats.faceExposure {
                // Skin a touch above middle grey.
                placement = evPhone + Double(face) - 0.67
                if Double(face) < Double(stats.logAverage) - 1.2 { reasons.append("Backlit, face in shade") } else { reasons.append("Face") }
            } else if backlitBySun || contrasty {
                placement = evPhone + Double(stats.centerWeighted) - 0.3
                reasons.append("Backlit")
            } else if stats.brightNeutralFraction > 0.3 && average > 12.5 {
                offset = 1.5
                reasons.append(average > 14 ? "Snow or sand" : "Bright, pale scene")
            } else if average < 6 && stats.p995 - stats.p50 > 4 {
                offset = -1.0
                reasons.append("Night, keep it dark")
            } else if stats.skyFraction > 0.5 {
                offset = -0.3
                reasons.append("Big sky")
            } else {
                reasons.append("Evaluative")
            }
            placement -= offset

            // Fit the scene to the stock's latitude.
            if let st = stock {
                let isNeg = st.kind != .slide
                let sLim = st.shadowLimit + (isNeg ? 0.7 * pushStops : pushStops)
                let hLim = st.highlightLimit - (isNeg ? 0.5 * pushStops : pushStops)
                let shadowAt = shadows - placement
                let highAt = highlights - placement
                if isNeg {
                    let need = (sLim + 0.7) - shadowAt
                    let room = (hLim - 0.5) - highAt
                    if need > 0.15 && room > 0.3 {
                        let shift = min(need, room, 2.0)
                        placement -= shift
                        reasons.append("\(ExposureMath.formatStops(shift)) to hold shadows")
                    }
                } else {
                    let over = highAt - (hLim - 0.2)
                    if over > 0.15 {
                        let shift = min(over, 2.0)
                        placement += shift
                        reasons.append("\(ExposureMath.formatStops(-shift)) to hold highlights")
                    }
                }
            }
        }

        let vsAverage = average - placement
        var reason = reasons.joined(separator: ", ")
        if mode == .matrix, abs(vsAverage) >= 1.0 / 6 { reason += ": \(ExposureMath.formatStops(vsAverage))" }
        return MeterResult(placementEV: placement, averageEV: average, reason: reason, sceneRange: range,
                           phoneClipped: stats.clipped > 0.01, shadowsEV: shadows, highlightsEV: highlights)
    }
}

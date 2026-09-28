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

/// What kind of scene the matrix meter thinks it is looking at.
enum SceneKind: Equatable {
    case face, backlitFace, backlit, snow, pale, night, sky, even
}

/// What the meter decided last time, so it only changes its mind for a real change.
struct MeterMemory {
    var kind: SceneKind?
    var pending: SceneKind?
    var pendingCount = 0
    var shiftThirds: Int?
    var placementThirds: Int?
    var rangeThirds: Int?

    mutating func reset() { self = MeterMemory() }

    /// Round `value` (stops) to thirds, but keep `previous` until the value is a quarter stop past it.
    static func hold(_ previous: Int?, _ value: Double) -> Int {
        let t = value * 3
        if let p = previous, abs(t - Double(p)) < 0.75 { return p }
        return Int(t.rounded())
    }
}

enum Meter {
    /// - Parameters:
    ///   - zone: for subject metering, stops above middle grey the subject should render (0 = Zone V).
    ///   - memory: the last decision; updated in place.
    ///   - newFrame: true when `stats` is a fresh frame (scene changes only count on fresh frames).
    static func evaluate(stats: FrameStats, mode: MeteringMode, zone: Double, stock: FilmStock?, pushStops: Double,
                         calibration: Double, sun: SunPosition?, attitude: Attitude?, display: DisplayOrientation,
                         memory: inout MeterMemory, newFrame: Bool) -> MeterResult {
        let evPhone = stats.exposure.ev100 + calibration
        let average = evPhone + Double(stats.logAverage)
        let shadows = evPhone + Double(stats.p5)
        let highlights = evPhone + Double(stats.p995)
        let rangeThirds = MeterMemory.hold(memory.rangeThirds, Double(stats.p995 - stats.p1))
        memory.rangeThirds = rangeThirds
        var placement: Double
        var label: String

        switch mode {
        case .subject:
            memory.kind = nil
            if let s = stats.subject {
                placement = evPhone + Double(s) - zone
                label = zone == 0 ? "Subject as middle grey" : "Subject placed \(ExposureMath.formatStops(zone)) from middle grey"
            } else {
                placement = evPhone + Double(stats.centerWeighted)
                label = "Tap a subject to meter it"
            }

        case .matrix:
            let base = 0.6 * Double(stats.centerWeighted) + 0.4 * Double(stats.logAverage)
            let current = memory.kind

            // Each test is a little easier to stay in than to enter, so a scene sitting on
            // a threshold doesn't flip back and forth.
            let backlitBySun: Bool = {
                guard let sun, let att = attitude, att.hasTrueNorth, sun.elevation > -2 else { return false }
                let fwd = simd_normalize(att.cameraForward)
                let ang = acos(max(-1, min(1, simd_dot(fwd, sun.worldVector)))) * 180 / .pi
                return ang < (current == .backlit ? 60 : 55)
            }()
            let wasBacklit = current == .backlit
            let contrasty = stats.p995 - stats.p50 > (wasBacklit ? 2.9 : 3.2)
                && stats.centerWeighted < stats.logAverage - (wasBacklit ? 0.15 : 0.3)
            let wasBright = current == .snow || current == .pale
            let wasNight = current == .night

            let candidate: SceneKind
            if let face = stats.faceExposure {
                let shade = current == .backlitFace ? 1.0 : 1.2
                candidate = Double(face) < Double(stats.logAverage) - shade ? .backlitFace : .face
            } else if backlitBySun || contrasty {
                candidate = .backlit
            } else if stats.brightNeutralFraction > (wasBright ? 0.25 : 0.3) && average > (wasBright ? 12.2 : 12.5) {
                candidate = average > (current == .snow ? 13.7 : 14) ? .snow : .pale
            } else if average < (wasNight ? 6.3 : 6) && stats.p995 - stats.p50 > (wasNight ? 3.7 : 4) {
                candidate = .night
            } else if stats.skyFraction > (current == .sky ? 0.42 : 0.5) {
                candidate = .sky
            } else {
                candidate = .even
            }

            // Switch only after the new reading has held for a few frames.
            var kind = current ?? candidate
            if candidate == kind {
                memory.pending = nil
                memory.pendingCount = 0
            } else if newFrame {
                if memory.pending == candidate { memory.pendingCount += 1 } else { memory.pending = candidate; memory.pendingCount = 1 }
                if memory.pendingCount >= 4 {
                    kind = candidate
                    memory.pending = nil
                    memory.pendingCount = 0
                }
            }
            memory.kind = kind

            placement = evPhone + base
            var offset = 0.0   // stops the scene average should sit above middle grey
            switch kind {
            case .face, .backlitFace:
                if let face = stats.faceExposure { placement = evPhone + Double(face) - 0.67 }
                label = kind == .face ? "Face: skin a touch above middle grey" : "Backlit face: exposed for the face"
            case .backlit:
                placement = evPhone + Double(stats.centerWeighted) - 0.3
                label = "Backlit: exposed for the subject, not the light behind it"
            case .snow:
                offset = 5.0 / 3
                label = "Snow or sand: +1⅔ to keep it white"
            case .pale:
                offset = 5.0 / 3
                label = "Bright, pale scene: +1⅔ to keep it bright"
            case .night:
                offset = -1
                label = "Night: −1 to keep it dark"
            case .sky:
                offset = -1.0 / 3
                label = "Big sky: −⅓ for the sky"
            case .even:
                label = "Even light"
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
                    // Negative film: use spare highlight room to hold more shadow detail.
                    let need = (sLim + 0.7) - shadowAt
                    let room = (hLim - 0.5) - highAt
                    let raw = need > 0 && room > 0.3 ? min(need, room, 2.0) : 0
                    let thirds = max(0, MeterMemory.hold(memory.shiftThirds, raw))
                    memory.shiftThirds = thirds
                    if thirds > 0 {
                        placement -= Double(thirds) / 3
                        label += " · \(ExposureMath.formatStops(Double(thirds) / 3)) for shadow detail"
                    }
                } else {
                    // Slide film: give up shadows to keep highlights.
                    let over = highAt - (hLim - 0.2)
                    let raw = over > 0 ? min(over, 2.0) : 0
                    let thirds = max(0, MeterMemory.hold(memory.shiftThirds, raw))
                    memory.shiftThirds = thirds
                    if thirds > 0 {
                        placement += Double(thirds) / 3
                        label += " · \(ExposureMath.formatStops(-Double(thirds) / 3)) to protect highlights"
                    }
                }
            } else {
                memory.shiftThirds = 0
            }
        }

        // Settle the reading on thirds of a stop, and only move it for a real change in the light.
        let placementThirds = MeterMemory.hold(memory.placementThirds, placement)
        memory.placementThirds = placementThirds
        placement = Double(placementThirds) / 3

        return MeterResult(placementEV: placement, averageEV: average, reason: label, sceneRange: Double(rangeThirds) / 3,
                           phoneClipped: stats.clipped > 0.01, shadowsEV: shadows, highlightsEV: highlights)
    }
}

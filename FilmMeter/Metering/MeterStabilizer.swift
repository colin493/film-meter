import Foundation

/// Smooths frame statistics over time, so a reading holds still while the phone does
/// and still follows quickly when the scene really changes.
///
/// Brightness values are smoothed as absolute EV (phone exposure plus the frame's own
/// statistic), so the phone's auto exposure hunting underneath doesn't show through.
final class MeterStabilizer {
    private var last: Date?
    private var avg: Double?, cw: Double?
    private var p1: Double?, p5: Double?, p50: Double?, p95: Double?, p99: Double?, p995: Double?
    private var subject: Double?, face: Double?
    private var clipped: Double?, sky: Double?, brightNeutral: Double?, saturation: Double?
    private var faceSeen = 0, faceMissed = 0
    private var facePresent = false

    func reset() {
        last = nil
        avg = nil; cw = nil
        p1 = nil; p5 = nil; p50 = nil; p95 = nil; p99 = nil; p995 = nil
        subject = nil; face = nil
        clipped = nil; sky = nil; brightNeutral = nil; saturation = nil
        faceSeen = 0; faceMissed = 0; facePresent = false
    }

    /// A new tap should be read as it is, not blended with the last subject.
    func resetSubject() { subject = nil }

    func update(_ s: FrameStats, now: Date = Date()) -> FrameStats {
        let dt = last.map { min(1, max(0.01, now.timeIntervalSince($0))) } ?? 1
        last = now
        let ev = s.exposure.ev100

        // Stops: small wobbles settle over about a second; a big move follows fast; a jump
        // of more than 1.5 stops means the phone points somewhere new, so take it at once.
        func level(_ old: Double?, _ new: Double) -> Double {
            guard let o = old else { return new }
            let d = abs(new - o)
            if d > 1.5 { return new }
            let tau = d > 0.5 ? 0.25 : 0.9
            return o + (1 - exp(-dt / tau)) * (new - o)
        }
        func fraction(_ old: Double?, _ new: Double) -> Double {
            guard let o = old else { return new }
            return o + (1 - exp(-dt / 0.9)) * (new - o)
        }
        func stops(_ store: inout Double?, _ value: Float) -> Float {
            let v = level(store, ev + Double(value))
            store = v
            return Float(v - ev)
        }
        func share(_ store: inout Double?, _ value: Float) -> Float {
            let v = fraction(store, Double(value))
            store = v
            return Float(v)
        }

        var out = s
        out.logAverage = stops(&avg, s.logAverage)
        out.centerWeighted = stops(&cw, s.centerWeighted)
        out.p1 = stops(&p1, s.p1)
        out.p5 = stops(&p5, s.p5)
        out.p50 = stops(&p50, s.p50)
        out.p95 = stops(&p95, s.p95)
        out.p99 = stops(&p99, s.p99)
        out.p995 = stops(&p995, s.p995)
        out.clipped = share(&clipped, s.clipped)
        out.skyFraction = share(&sky, s.skyFraction)
        out.brightNeutralFraction = share(&brightNeutral, s.brightNeutralFraction)
        out.meanSaturation = share(&saturation, s.meanSaturation)

        if let sub = s.subject {
            out.subject = stops(&subject, sub)
        } else {
            subject = nil
        }

        // Faces come and go between detections; only count one after it has held briefly,
        // and only drop it after it has been gone for about a second.
        if let f = s.faceExposure {
            faceSeen += 1
            faceMissed = 0
            let v = level(face, ev + Double(f))
            face = v
            if faceSeen >= 2 { facePresent = true }
        } else {
            faceMissed += 1
            faceSeen = 0
            if faceMissed >= 8 { facePresent = false; face = nil }
        }
        if facePresent, let f = face {
            out.faceExposure = Float(f - ev)
        } else {
            out.faceExposure = nil
        }
        return out
    }
}

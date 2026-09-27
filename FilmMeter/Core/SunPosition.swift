import Foundation

/// NOAA solar position. Works offline from date, latitude and longitude.
struct SunPosition: Codable, Hashable {
    var azimuth: Double    // degrees clockwise from true north
    var elevation: Double  // degrees above the horizon

    static func compute(date: Date, latitude: Double, longitude: Double) -> SunPosition {
        let rad = Double.pi / 180
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let t = (jd - 2451545.0) / 36525.0
        var l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c1: Double = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
        let c2: Double = sin(2 * m * rad) * (0.019993 - 0.000101 * t)
        let c3: Double = sin(3 * m * rad) * 0.000289
        let c = c1 + c2 + c3
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let epsInner: Double = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let eps0: Double = 23 + (26 + epsInner / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * rad)
        let decl = asin(sin(eps * rad) * sin(lambda * rad))
        let y = pow(tan(eps * rad / 2), 2)
        let s2l = sin(2 * l0 * rad), sM = sin(m * rad), c2l = cos(2 * l0 * rad)
        let s4l = sin(4 * l0 * rad), s2m = sin(2 * m * rad)
        let eq1: Double = y * s2l - 2 * e * sM
        let eq2: Double = 4 * e * y * sM * c2l - 0.5 * y * y * s4l - 1.25 * e * e * s2m
        let eqTime = 4 / rad * (eq1 + eq2)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let utcMinutes = Double(comps.hour ?? 0) * 60 + Double(comps.minute ?? 0) + Double(comps.second ?? 0) / 60
        var tst = (utcMinutes + eqTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if tst < 0 { tst += 1440 }
        var ha = tst / 4 - 180
        if ha < -180 { ha += 360 }
        let lat = latitude * rad
        var cosZ = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha * rad)
        cosZ = min(1, max(-1, cosZ))
        let zenith = acos(cosZ)
        var elevation = 90 - zenith / rad
        // Atmospheric refraction (approximate) near the horizon.
        if elevation > -0.575 && elevation < 85 {
            let te = tan(elevation * rad)
            let corr: Double
            if elevation > 5 {
                corr = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)
            } else {
                let a1: Double = -12.79 + elevation * 0.711
                let a2: Double = 103.4 + elevation * a1
                let a3: Double = -518.2 + elevation * a2
                corr = 1735 + elevation * a3
            }
            elevation += corr / 3600
        }
        var az: Double
        let denom = cos(lat) * sin(zenith)
        if abs(denom) > 1e-6 {
            var cosAz = (sin(lat) * cos(zenith) - sin(decl)) / denom
            cosAz = min(1, max(-1, cosAz))
            az = acos(cosAz) / rad
            if ha > 0 { az = (az + 180).truncatingRemainder(dividingBy: 360) } else { az = (540 - az).truncatingRemainder(dividingBy: 360) }
        } else {
            az = lat > 0 ? 180 : 0
        }
        return SunPosition(azimuth: az, elevation: elevation)
    }

    /// Unit vector in the world frame used by `Attitude` (x = true north, y = west, z = up).
    var worldVector: SIMD3<Double> {
        let rad = Double.pi / 180
        let el = elevation * rad, az = azimuth * rad
        return SIMD3(cos(el) * cos(az), -cos(el) * sin(az), sin(el))
    }
}

import Foundation
import simd

/// How the phone is held while composing. Decides which device axes are "right" and "up" in the image.
enum DisplayOrientation: String, Codable {
    case portrait, landscapeRight, landscapeLeft, portraitUpsideDown

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Image axes expressed in the device frame (x right, y up, z out of the screen).
    var imageAxes: (right: SIMD3<Double>, up: SIMD3<Double>) {
        switch self {
        case .portrait: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .landscapeRight: return (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        case .landscapeLeft: return (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        case .portraitUpsideDown: return (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        }
    }
}

/// Device attitude as a rotation from the device frame into the world frame (x = true north, y = west, z = up).
struct Attitude: Codable, Hashable {
    var m: [Double]   // row-major 3x3
    var hasTrueNorth: Bool

    func toWorld(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z,
              m[3] * v.x + m[4] * v.y + m[5] * v.z,
              m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }

    /// Camera pointing direction (back camera looks along −z of the device).
    var cameraForward: SIMD3<Double> { toWorld(SIMD3(0, 0, -1)) }
}

/// Per-cell sky polarization for the framed view, computed once per capture.
struct SkyGrid: Codable, Hashable {
    var cols: Int
    var rows: Int
    var dop: [Float]        // degree of polarization, 0...1
    var angle: [Float]      // E-vector angle in the image, radians from image-right toward image-up
    var elevation: [Float]  // degrees above the horizon of the viewing ray
    var sunElevation: Double

    static let maxDOP = 0.75

    static func compute(attitude: Attitude, sun: SunPosition, orientation: DisplayOrientation,
                        tanHalfWidth: Double, tanHalfHeight: Double, cols: Int = 24, rows: Int = 32) -> SkyGrid {
        let axes = orientation.imageAxes
        let fwdD = SIMD3<Double>(0, 0, -1)
        let s = sun.worldVector
        var dop = [Float](repeating: 0, count: cols * rows)
        var ang = [Float](repeating: 0, count: cols * rows)
        var elev = [Float](repeating: 0, count: cols * rows)
        let rightW = attitude.toWorld(axes.right)
        let upW = attitude.toWorld(axes.up)
        for r in 0..<rows {
            for c in 0..<cols {
                let u = (Double(c) + 0.5) / Double(cols) * 2 - 1          // −1 left … +1 right
                let v = 1 - (Double(r) + 0.5) / Double(rows) * 2          // +1 top … −1 bottom
                let offR: SIMD3<Double> = (u * tanHalfWidth) * axes.right
                let offU: SIMD3<Double> = (v * tanHalfHeight) * axes.up
                let rayD = simd_normalize(fwdD + offR + offU)
                let ray = simd_normalize(attitude.toWorld(rayD))
                let i = r * cols + c
                elev[i] = Float(asin(max(-1, min(1, ray.z))) * 180 / .pi)
                guard sun.elevation > -4 else { continue }
                let cg = max(-1, min(1, simd_dot(ray, s)))
                let sin2 = 1 - cg * cg
                dop[i] = Float(maxDOP * sin2 / (1 + cg * cg))
                let e = simd_cross(ray, s)
                let len = simd_length(e)
                guard len > 1e-6 else { dop[i] = 0; continue }
                let en = e / len
                let rp = simd_normalize(rightW - simd_dot(rightW, ray) * ray)
                let up = simd_normalize(upW - simd_dot(upW, ray) * ray)
                ang[i] = Float(atan2(simd_dot(en, up), simd_dot(en, rp)))
            }
        }
        return SkyGrid(cols: cols, rows: rows, dop: dop, angle: ang, elevation: elev, sunElevation: sun.elevation)
    }

    /// Bilinear sample at normalized image coordinates (x right, y down, both 0...1).
    func sample(x: Float, y: Float) -> (dop: Float, angle: Float, elevation: Float) {
        let fx = max(0, min(Float(cols) - 1.001, x * Float(cols) - 0.5))
        let fy = max(0, min(Float(rows) - 1.001, y * Float(rows) - 0.5))
        let x0 = Int(fx), y0 = Int(fy)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ a: [Float], _ cx: Int, _ cy: Int) -> Float { a[min(rows - 1, cy) * cols + min(cols - 1, cx)] }
        func lerp2(_ a: [Float]) -> Float {
            let top = at(a, x0, y0) * (1 - tx) + at(a, x0 + 1, y0) * tx
            let bot = at(a, x0, y0 + 1) * (1 - tx) + at(a, x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bot * ty
        }
        // Angles are axial (period π): average them as doubled-angle vectors.
        func lerpAngle() -> Float {
            var cx: Float = 0, sy: Float = 0
            let pts = [(x0, y0, (1 - tx) * (1 - ty)), (x0 + 1, y0, tx * (1 - ty)), (x0, y0 + 1, (1 - tx) * ty), (x0 + 1, y0 + 1, tx * ty)]
            for (px, py, w) in pts {
                let a = at(angle, px, py)
                cx += w * cos(2 * a); sy += w * sin(2 * a)
            }
            return atan2(sy, cx) / 2
        }
        return (lerp2(dop), lerpAngle(), lerp2(elevation))
    }

    /// Relative transmission of sky light through a polarizer whose axis sits at `axis` (radians, image coords),
    /// after the filter factor has been compensated.
    static func factor(dop: Float, angle: Float, axis: Float) -> Float {
        let d = cos(angle - axis)
        return (1 - dop) + 2 * dop * d * d
    }
}

enum PolarizerAxis {
    /// The dot sits at the top of the lens. With a rectangular format held vertically, the dot turns sideways.
    static func angle(format: FilmFormat, orientation: DisplayOrientation) -> Float {
        if format.isSquare { return .pi / 2 }
        return orientation.isLandscape ? .pi / 2 : 0
    }
}

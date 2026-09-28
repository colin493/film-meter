import Accelerate
import CoreGraphics
import CoreVideo
import ImageIO
import Vision
import simd

/// Maps between the camera sensor's native landscape frame and the upright (oriented) view.
struct OrientationMap {
    let orientation: CGImagePropertyOrientation

    init(_ display: DisplayOrientation) {
        switch display {
        case .portrait: orientation = .right
        case .landscapeRight: orientation = .up
        case .landscapeLeft: orientation = .down
        case .portraitUpsideDown: orientation = .left
        }
    }

    /// Upright normalized (top-left origin) → sensor normalized.
    func toSensor(_ p: CGPoint) -> CGPoint {
        switch orientation {
        case .right: return CGPoint(x: p.y, y: 1 - p.x)
        case .down: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .left: return CGPoint(x: 1 - p.y, y: p.x)
        default: return p
        }
    }

    /// Sensor normalized → upright normalized (top-left origin).
    func toUpright(_ p: CGPoint) -> CGPoint {
        switch orientation {
        case .right: return CGPoint(x: 1 - p.y, y: p.x)
        case .down: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .left: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    func toSensor(_ r: CGRect) -> CGRect {
        let a = toSensor(CGPoint(x: r.minX, y: r.minY)), b = toSensor(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var swapsAxes: Bool { orientation == .right || orientation == .left }
}

struct FrameStats {
    var exposure: PhoneExposure
    /// Per-channel 0.5 / 99.5 percentiles of log2(L·gain / 0.18), used to level the film render.
    var lo = SIMD3<Float>(-4, -4, -4)
    var hi = SIMD3<Float>(3, 3, 3)
    var loY: Float = -4
    var hiY: Float = 3
    /// Luminance 0.5 / 99.5 percentiles (with filter colour), used to level colour film on all channels at once.
    var loL: Float = -4
    var hiL: Float = 3
    /// Luminance exposure percentiles (stops re: 18% grey at the phone's exposure).
    var p1: Float = -4, p5: Float = -3, p50: Float = 0, p95: Float = 2, p99: Float = 2.5, p995: Float = 2.7
    var logAverage: Float = 0
    var centerWeighted: Float = 0
    var subject: Float?
    var clipped: Float = 0
    var skyFraction: Float = 0
    var brightNeutralFraction: Float = 0
    var meanSaturation: Float = 0
    var faces: [CGRect] = []          // upright normalized, top-left origin
    var faceExposure: Float?
    /// Small upright linear-light thumbnail of the framed area (row-major, top-left origin).
    var thumb: [SIMD3<Float>] = []
    var thumbWidth = 0
    var thumbHeight = 0
}

struct AnalyzerConfig {
    var gains = SIMD3<Float>(1, 1, 1)
    var bwWeights = SIMD3<Float>(0.3, 0.56, 0.14)
    var display: DisplayOrientation = .portrait
    /// Framed area in upright normalized coordinates.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Subject point in upright normalized coordinates.
    var subjectPoint: CGPoint?
}

final class FrameAnalyzer {
    private let tw = 128, th = 96
    private var scaled: [UInt8]
    private var lastFaceTime = Date.distantPast
    private var faces: [CGRect] = []
    private let decode: [Float] = (0..<256).map { ColorMath.srgbDecode(Float($0) / 255) }

    init() { scaled = [UInt8](repeating: 0, count: 128 * 96 * 4) }

    func analyze(_ pb: CVPixelBuffer, exposure: PhoneExposure, config: AnalyzerConfig) -> FrameStats {
        var stats = FrameStats(exposure: exposure)
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return stats }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return stats }
        var src = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let ok: vImage_Error = scaled.withUnsafeMutableBytes { dst in
            var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * 4)
            return vImageScale_ARGB8888(&src, &d, nil, vImage_Flags(kvImageNoFlags))
        }
        guard ok == kvImageNoError else { return stats }

        let map = OrientationMap(config.display)
        // Upright thumbnail dimensions
        let uw = map.swapsAxes ? th : tw, uh = map.swapsAxes ? tw : th
        let crop = config.crop
        let x0 = max(0, min(uw - 1, Int((crop.minX * CGFloat(uw)).rounded(.down))))
        let x1 = max(x0 + 1, min(uw, Int((crop.maxX * CGFloat(uw)).rounded(.up))))
        let y0 = max(0, min(uh - 1, Int((crop.minY * CGFloat(uh)).rounded(.down))))
        let y1 = max(y0 + 1, min(uh, Int((crop.maxY * CGFloat(uh)).rounded(.up))))
        let cw = x1 - x0, ch = y1 - y0

        var eY = [Float](); eY.reserveCapacity(cw * ch)
        var eR = [Float](), eG = [Float](), eB = [Float](), eW = [Float](), eL = [Float]()
        eR.reserveCapacity(cw * ch); eG.reserveCapacity(cw * ch); eB.reserveCapacity(cw * ch); eW.reserveCapacity(cw * ch)
        eL.reserveCapacity(cw * ch)
        var thumb = [SIMD3<Float>](repeating: .zero, count: cw * ch)
        var sumLog: Float = 0, sumW: Float = 0, sumWLog: Float = 0
        var clipped = 0, sky = 0, skyN = 0, brightNeutral = 0
        var satSum: Float = 0
        let gl = SIMD3<Float>(log2f(config.gains.x), log2f(config.gains.y), log2f(config.gains.z))

        for uy in y0..<y1 {
            for ux in x0..<x1 {
                // upright pixel → sensor pixel in the scaled buffer
                let sp = map.toSensor(CGPoint(x: (Double(ux) + 0.5) / Double(uw), y: (Double(uy) + 0.5) / Double(uh)))
                let sx = min(tw - 1, Int(sp.x * Double(tw))), sy = min(th - 1, Int(sp.y * Double(th)))
                let o = (sy * tw + sx) * 4
                let b8 = scaled[o], g8 = scaled[o + 1], r8 = scaled[o + 2]
                let lin = SIMD3<Float>(decode[Int(r8)], decode[Int(g8)], decode[Int(b8)])
                thumb[(uy - y0) * cw + (ux - x0)] = lin
                let y = max(1e-5, ColorMath.luminance(lin))
                let e = log2f(y / 0.18)
                eY.append(e)
                eR.append(log2f(max(1e-5, lin.x) / 0.18) + gl.x)
                eG.append(log2f(max(1e-5, lin.y) / 0.18) + gl.y)
                eB.append(log2f(max(1e-5, lin.z) / 0.18) + gl.z)
                eW.append(log2f(max(1e-5, simd_dot(config.bwWeights, lin * config.gains)) / 0.18))
                eL.append(log2f(max(1e-5, ColorMath.luminance(lin * config.gains)) / 0.18))
                sumLog += e
                let nx = (Float(ux - x0) + 0.5) / Float(cw) - 0.5, ny = (Float(uy - y0) + 0.5) / Float(ch) - 0.5
                let w = expf(-(nx * nx + ny * ny) / 0.08)
                sumW += w; sumWLog += w * e
                if max(r8, max(g8, b8)) > 250 { clipped += 1 }
                let mx = max(lin.x, max(lin.y, lin.z)), mn = min(lin.x, min(lin.y, lin.z))
                let sat = mx > 1e-4 ? (mx - mn) / mx : 0
                satSum += sat
                if uy - y0 < ch / 3 {
                    skyN += 1
                    if lin.z > lin.x * 1.15 && lin.z >= lin.y * 0.98 && e > -1 { sky += 1 }
                }
                if e > 0.8 && sat < 0.12 { brightNeutral += 1 }
            }
        }
        let n = eY.count
        guard n > 16 else { return stats }
        func pct(_ a: inout [Float], _ q: [Float]) -> [Float] {
            a.sort()
            return q.map { a[min(a.count - 1, max(0, Int(Float(a.count - 1) * $0)))] }
        }
        let py = pct(&eY, [0.01, 0.05, 0.5, 0.95, 0.99, 0.995])
        stats.p1 = py[0]; stats.p5 = py[1]; stats.p50 = py[2]; stats.p95 = py[3]; stats.p99 = py[4]; stats.p995 = py[5]
        let r = pct(&eR, [0.005, 0.995]), g = pct(&eG, [0.005, 0.995]), b = pct(&eB, [0.005, 0.995]), wq = pct(&eW, [0.005, 0.995])
        stats.lo = SIMD3(r[0], g[0], b[0]); stats.hi = SIMD3(r[1], g[1], b[1])
        stats.loY = wq[0]; stats.hiY = wq[1]
        let lq = pct(&eL, [0.005, 0.995])
        stats.loL = lq[0]; stats.hiL = lq[1]
        stats.logAverage = sumLog / Float(n)
        stats.centerWeighted = sumW > 0 ? sumWLog / sumW : stats.logAverage
        stats.clipped = Float(clipped) / Float(n)
        stats.skyFraction = skyN > 0 ? Float(sky) / Float(skyN) : 0
        stats.brightNeutralFraction = Float(brightNeutral) / Float(n)
        stats.meanSaturation = satSum / Float(n)
        stats.thumb = thumb; stats.thumbWidth = cw; stats.thumbHeight = ch

        // Subject: mean of a small window around the tap (in upright coordinates within the crop).
        if let sp = config.subjectPoint {
            stats.subject = regionExposure(thumb: thumb, w: cw, h: ch, crop: crop,
                                           rect: CGRect(x: sp.x - 0.035, y: sp.y - 0.035, width: 0.07, height: 0.07))
        }

        // Faces, a couple of times a second.
        if Date().timeIntervalSince(lastFaceTime) > 0.5 {
            lastFaceTime = Date()
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: map.orientation, options: [:])
            if (try? handler.perform([request])) != nil {
                faces = (request.results ?? []).map { f in
                    let bb = f.boundingBox
                    return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
                }
            } else {
                faces = []
            }
        }
        stats.faces = faces
        if let biggest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            stats.faceExposure = regionExposure(thumb: thumb, w: cw, h: ch, crop: crop, rect: biggest.insetBy(dx: biggest.width * 0.2, dy: biggest.height * 0.2))
        }
        return stats
    }

    /// Mean log exposure of an upright-normalized rect, using the cropped thumbnail.
    private func regionExposure(thumb: [SIMD3<Float>], w: Int, h: Int, crop: CGRect, rect: CGRect) -> Float? {
        guard crop.width > 0, crop.height > 0 else { return nil }
        let rx0 = Int(((rect.minX - crop.minX) / crop.width * CGFloat(w)).rounded(.down))
        let rx1 = Int(((rect.maxX - crop.minX) / crop.width * CGFloat(w)).rounded(.up))
        let ry0 = Int(((rect.minY - crop.minY) / crop.height * CGFloat(h)).rounded(.down))
        let ry1 = Int(((rect.maxY - crop.minY) / crop.height * CGFloat(h)).rounded(.up))
        var sum: Float = 0, count = 0
        let ya = max(0, ry0), yb = min(h, max(ry1, ry0 + 1))
        let xa = max(0, rx0), xb = min(w, max(rx1, rx0 + 1))
        guard ya < yb, xa < xb else { return nil }
        for y in ya..<yb {
            for x in xa..<xb {
                sum += ColorMath.luminance(thumb[y * w + x]); count += 1
            }
        }
        guard count > 0 else { return nil }
        return log2f(max(1e-5, sum / Float(count)) / 0.18)
    }
}

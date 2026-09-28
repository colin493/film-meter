import Accelerate
import AVFoundation
import CoreImage
import UIKit
import simd

/// A locked, high-dynamic-range frame plus its depth, ready to re-render at any setting.
final class LockedFrame: Identifiable {
    let id: UUID
    var meta: CompositionMeta
    let width: Int
    let height: Int
    /// Linear light, RGBA interleaved; 0.18 = middle grey at the base frame's exposure.
    let linear: [Float]
    /// Metres, depthWidth × depthHeight, or nil when the phone gave no depth.
    let depth: [Float]?

    init(meta: CompositionMeta, width: Int, height: Int, linear: [Float], depth: [Float]?) {
        self.id = meta.id
        self.meta = meta
        self.width = width
        self.height = height
        self.linear = linear
        self.depth = depth
    }

    var hasDepth: Bool { depth != nil && meta.depthWidth > 0 }

    func depthAt(x: Float, y: Float) -> Float? {
        guard let d = depth, meta.depthWidth > 1, meta.depthHeight > 1 else { return nil }
        let w = meta.depthWidth, h = meta.depthHeight
        let fx = max(0, min(Float(w) - 1.001, x * Float(w) - 0.5)), fy = max(0, min(Float(h) - 1.001, y * Float(h) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), tx = fx - Float(x0), ty = fy - Float(y0)
        func v(_ a: Int, _ b: Int) -> Float { let z = d[b * w + a]; return z.isFinite && z > 0 ? z : 1000 }
        let top = v(x0, y0) * (1 - tx) + v(x0 + 1, y0) * tx
        let bot = v(x0, y0 + 1) * (1 - tx) + v(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bot * ty
    }
}

enum StillBuilder {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Merge the bracket into one linear image in the framed, upright view.
    static func build(capture: BracketCapture, display: DisplayOrientation, cropAspect: Double, zoom: Double = 1, longEdge: Int = 1440)
        -> (linear: [Float], width: Int, height: Int, depth: [Float]?, depthWidth: Int, depthHeight: Int)? {
        guard let first = capture.frames.first else { return nil }
        let map = OrientationMap(display)
        let bw = Double(CVPixelBufferGetWidth(first.buffer)), bh = Double(CVPixelBufferGetHeight(first.buffer))
        let uprightAspect = map.swapsAxes ? bh / bw : bw / bh
        let crop = LiveProcessor.cropRect(imageAspect: uprightAspect, target: cropAspect, zoom: zoom)
        let upW = map.swapsAxes ? bh : bw, upH = map.swapsAxes ? bw : bh
        let cropW = crop.width * upW, cropH = crop.height * upH
        let scale = Double(longEdge) / max(cropW, cropH)
        let W = max(1, Int((cropW * scale).rounded())), H = max(1, Int((cropH * scale).rounded()))
        let n = W * H

        var sum = [Float](repeating: 0, count: n * 3)
        var wsum = [Float](repeating: 0, count: n)
        var fallback = [Float](repeating: 0, count: n * 3)   // darkest frame, for pixels clipped everywhere
        var fallbackRatio = Double.infinity
        let decode: [Float] = (0..<1024).map { ColorMath.srgbDecode(Float($0) / 1023) }

        for f in capture.frames {
            guard let px = renderUpright(f.buffer, map: map, crop: crop, width: W, height: H) else { continue }
            let r = Float(f.ratio)
            let isDarkest = f.ratio < fallbackRatio
            if isDarkest { fallbackRatio = f.ratio }
            px.withUnsafeBufferPointer { p in
                for i in 0..<n {
                    let v0 = max(0, min(1, p[i * 4])), v1 = max(0, min(1, p[i * 4 + 1])), v2 = max(0, min(1, p[i * 4 + 2]))
                    let l0 = decode[Int(v0 * 1023)], l1 = decode[Int(v1 * 1023)], l2 = decode[Int(v2 * 1023)]
                    let vmax = max(v0, max(v1, v2)), vmin = min(v0, min(v1, v2))
                    var w = min(1, vmin / 0.04) * min(1, max(0, (0.96 - vmax) / 0.10))
                    w = max(w, 1e-4)
                    sum[i * 3] += w * l0 / r; sum[i * 3 + 1] += w * l1 / r; sum[i * 3 + 2] += w * l2 / r
                    wsum[i] += w
                    if isDarkest {
                        fallback[i * 3] = l0 / r; fallback[i * 3 + 1] = l1 / r; fallback[i * 3 + 2] = l2 / r
                    }
                }
            }
        }

        var linear = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            if wsum[i] > 3e-4 {
                linear[i * 4] = sum[i * 3] / wsum[i]; linear[i * 4 + 1] = sum[i * 3 + 1] / wsum[i]; linear[i * 4 + 2] = sum[i * 3 + 2] / wsum[i]
            } else {
                linear[i * 4] = fallback[i * 3]; linear[i * 4 + 1] = fallback[i * 3 + 1]; linear[i * 4 + 2] = fallback[i * 3 + 2]
            }
        }

        // Depth, oriented and cropped the same way.
        var depthOut: [Float]?
        var dW = 0, dH = 0
        if let dd = capture.depth {
            let d32 = dd.depthDataType == kCVPixelFormatType_DepthFloat32 ? dd : dd.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let map32 = d32.depthDataMap
            let dw = Double(CVPixelBufferGetWidth(map32)), dh = Double(CVPixelBufferGetHeight(map32))
            let dUpW = map.swapsAxes ? dh : dw, dUpH = map.swapsAxes ? dw : dh
            let dScale = min(1, 480 / max(crop.width * dUpW, crop.height * dUpH))
            dW = max(2, Int((crop.width * dUpW * dScale).rounded())); dH = max(2, Int((crop.height * dUpH * dScale).rounded()))
            if let img = CIImage(depthData: d32) ?? Optional(CIImage(cvPixelBuffer: map32, options: [.colorSpace: NSNull()])),
               let px = renderUpright(image: img, map: map, crop: crop, width: dW, height: dH) {
                depthOut = (0..<(dW * dH)).map { px[$0 * 4] }
            } else {
                dW = 0; dH = 0
            }
        }
        return (linear, W, H, depthOut, dW, dH)
    }

    static func renderUpright(_ pb: CVPixelBuffer, map: OrientationMap, crop: CGRect, width: Int, height: Int) -> [Float]? {
        renderUpright(image: CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()]), map: map, crop: crop, width: width, height: height)
    }

    /// Orient, crop to the framed area and resample to width × height; returns RGBA floats, top row first.
    static func renderUpright(image: CIImage, map: OrientationMap, crop: CGRect, width: Int, height: Int) -> [Float]? {
        let img = image.oriented(map.orientation)
        let ext = img.extent
        let rect = CGRect(x: ext.minX + crop.minX * ext.width, y: ext.minY + (1 - crop.maxY) * ext.height,
                          width: crop.width * ext.width, height: crop.height * ext.height)
        let sx = CGFloat(width) / rect.width, sy = CGFloat(height) / rect.height
        let placed = img.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var out = [Float](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { p in
            context.render(placed, toBitmap: p.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        }
        return out
    }
}

struct StillParams: Equatable {
    var exposureShift: Double = 0      // stops more exposure than the locked placement
    var aperture: Double = 8
    var focusM: Double?
    var gains = SIMD3<Float>(1, 1, 1)
    var polarizerAxis: Float?
    var look = FilmLook()
    var grain: Float = 0
    var showZebras = true
}

struct StillStats {
    var highlightClip: Float = 0
    var shadowClip: Float = 0
}

final class StillRenderer {
    let frame: LockedFrame
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private var filteredKey = ""
    private var filtered: [Float] = []
    private var blurredKey = ""
    private var blurred: [Float] = []

    init(frame: LockedFrame) { self.frame = frame }

    private var W: Int { frame.width }
    private var H: Int { frame.height }

    /// Width of the framed image on film, in mm.
    private var filmWidthMM: Double {
        let f = frame.meta.format.size
        return W >= H ? f.long : f.short
    }

    func render(_ p: StillParams) -> (image: CGImage?, zebra: CGImage?, stats: StillStats) {
        let n = W * H
        // 1. Filter colour and polarizer (cached until filters change).
        let fKey = "\(p.gains)|\(p.polarizerAxis.map { String($0) } ?? "none")"
        if fKey != filteredKey {
            filtered = applyFilters(gains: p.gains, axis: p.polarizerAxis)
            filteredKey = fKey
            blurredKey = ""
        }
        // 2. Depth of field (cached per aperture and focus).
        let bKey = "\(p.aperture)|\(p.focusM ?? -1)"
        if bKey != blurredKey {
            blurred = applyDepthOfField(filtered, aperture: p.aperture, focusM: p.focusM)
            blurredKey = bKey
        }
        // 3. Exposure shift and film levelling.
        let k = Float(frame.meta.baseEV100 - frame.meta.placementEV + p.exposureShift)
        var look = p.look
        look.k = k
        var s = [Float](repeating: 1, count: n * 4)
        var sampW = [Float]()
        let stride = max(1, n / 20000)
        var hiClip = 0, loClip = 0
        var zebra = [UInt8](repeating: 0, count: n * 4)
        let showZ = p.showZebras && look.mode != .neutral
        blurred.withUnsafeBufferPointer { bp in
            for i in 0..<n {
                let x = SIMD3<Float>(max(1e-7, bp[i * 4]), max(1e-7, bp[i * 4 + 1]), max(1e-7, bp[i * 4 + 2]))
                s[i * 4] = FilmPipeline.logEncode(x.x); s[i * 4 + 1] = FilmPipeline.logEncode(x.y); s[i * 4 + 2] = FilmPipeline.logEncode(x.z)
                let wv = look.mode == .bwNegative ? simd_dot(look.bwWeights, x) : ColorMath.luminance(x)
                let ey = log2f(max(1e-7, wv) / 0.18)
                if i % stride == 0 { sampW.append(ey) }
                if showZ {
                    let e = ey + k
                    let px = i % W, py = i / W
                    if e > look.highlightLimit {
                        hiClip += 1
                        if ((px + py) / 6) % 2 == 0 { zebra[i * 4] = 230; zebra[i * 4 + 1] = 40; zebra[i * 4 + 2] = 40; zebra[i * 4 + 3] = 230 }
                    } else if e < look.shadowLimit {
                        loClip += 1
                        if ((px - py + 100_000) / 6) % 2 == 0 { zebra[i * 4] = 40; zebra[i * 4 + 1] = 110; zebra[i * 4 + 2] = 230; zebra[i * 4 + 3] = 230 }
                    }
                }
            }
        }
        func pct(_ a: inout [Float], _ q: Float) -> Float {
            guard !a.isEmpty else { return 0 }
            a.sort()
            return a[min(a.count - 1, max(0, Int(Float(a.count - 1) * q)))]
        }
        // One range for all channels (luminance for colour, the stock's weights for B&W). This keeps the
        // phone's white balance: levelling channels separately tinted the frame with whatever light
        // source happened to be brightest, once the bracket recovered its real colour.
        let lo = pct(&sampW, 0.001), hi = pct(&sampW, 0.999)
        look.lo = SIMD3(repeating: lo); look.hi = SIMD3(repeating: hi)

        // 4. Film look via a composite cube on the GPU.
        let cube = FilmPipeline.buildCube(size: 41, input: .logEncoded, look: look)
        let sData = s.withUnsafeBufferPointer { Data(buffer: $0) }
        var img = CIImage(bitmapData: sData, bytesPerRow: W * 16, size: CGSize(width: W, height: H), format: .RGBAf, colorSpace: nil)
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 41, "inputCubeData": cube])
        if p.grain > 0.001 { img = Grain.apply(to: img, amount: p.grain, seed: 7) }
        let cg = ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: p3)

        var zImg: CGImage?
        if showZ {
            zImg = zebra.withUnsafeMutableBytes { zp -> CGImage? in
                guard let ctx = CGContext(data: zp.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return ctx.makeImage()
            }
        }
        return (cg, zImg, StillStats(highlightClip: Float(hiClip) / Float(max(1, n)), shadowClip: Float(loClip) / Float(max(1, n))))
    }

    private func applyFilters(gains: SIMD3<Float>, axis: Float?) -> [Float] {
        var out = frame.linear
        let sky = frame.meta.sky
        let W = self.W, H = self.H
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<H {
                for x in 0..<W {
                    let i = (y * W + x) * 4
                    var c = SIMD3<Float>(o[i], o[i + 1], o[i + 2])
                    if let axis, let sky {
                        let smp = sky.sample(x: (Float(x) + 0.5) / Float(W), y: (Float(y) + 0.5) / Float(H))
                        c *= PolarizerModel.multiplier(linear: c, dop: smp.dop, angle: smp.angle, elevation: smp.elevation, axis: axis)
                    }
                    c *= gains
                    o[i] = c.x; o[i + 1] = c.y; o[i + 2] = c.z
                }
            }
        }
        return out
    }

    /// Blur each pixel by the film camera's blur circle for its depth.
    private func applyDepthOfField(_ src: [Float], aperture: Double, focusM: Double?) -> [Float] {
        guard frame.hasDepth, let focus = focusM else { return src }
        let W = self.W, H = self.H
        let maxR: Float = 48
        let f = frame.meta.focalLength
        let widthMM = filmWidthMM
        var mask = [Float](repeating: 0, count: W * H * 4)
        var anyBlur = false
        for y in 0..<H {
            for x in 0..<W {
                let d = frame.depthAt(x: (Float(x) + 0.5) / Float(W), y: (Float(y) + 0.5) / Float(H)) ?? 1000
                let c = DepthOfField.blurDiameterMM(focalMM: f, aperture: aperture, focusM: focus, objectM: Double(d))
                let rPx = Float(c / widthMM) * Float(W) / 2
                let m = min(1, rPx / maxR)
                if m > 0.02 { anyBlur = true }
                let i = (y * W + x) * 4
                mask[i] = m; mask[i + 1] = m; mask[i + 2] = m; mask[i + 3] = 1
            }
        }
        guard anyBlur else { return src }
        let size = CGSize(width: W, height: H)
        let input = CIImage(bitmapData: src.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: W * 16, size: size, format: .RGBAf, colorSpace: nil)
        let maskImg = CIImage(bitmapData: mask.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: W * 16, size: size, format: .RGBAf, colorSpace: nil)
        // A disc of radius r looks like a Gaussian of sigma ≈ r / 2.
        let blurred = input.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": maskImg.clampedToExtent(), kCIInputRadiusKey: maxR / 2])
            .cropped(to: CGRect(origin: .zero, size: size))
        var out = [Float](repeating: 0, count: W * H * 4)
        out.withUnsafeMutableBytes { p in
            ci.render(blurred, toBitmap: p.baseAddress!, rowBytes: W * 16, bounds: CGRect(origin: .zero, size: size), format: .RGBAf, colorSpace: nil)
        }
        return out
    }
}

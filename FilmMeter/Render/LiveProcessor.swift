import AVFoundation
import CoreImage
import simd

/// Settings the live view needs, pushed from the main thread.
struct LiveConfig {
    var look = FilmLook()
    var showFilm = true
    /// Scene EV100 that lands on the film's middle grey; nil until metered.
    var placementEV: Double?
    var calibration: Double = 0
    var display: DisplayOrientation = .portrait
    /// Framed aspect (width / height) of the upright view.
    var cropAspect: Double = 2.0 / 3.0
    var subjectPoint: CGPoint?
    var grain: Float = 0
    var polarizerAxis: Float?        // nil when no polarizer is mounted
    var tanHalfWidth: Double = 0.4
    var tanHalfHeight: Double = 0.6
    /// Zoom the phone couldn't do optically (it limits zoom while streaming depth), applied as a centre crop.
    var digitalZoom: Double = 1
}

/// Receives camera frames, measures them, and renders the film preview.
final class LiveProcessor: CameraFrameSink {
    let renderer = LiveRenderer()
    private let analyzer = FrameAnalyzer()
    private let lock = NSLock()
    private var config = LiveConfig()
    private var configVersion = 0
    private var frameCount = 0

    private let cubeQueue = DispatchQueue(label: "film.cube", qos: .userInitiated)
    private var cube: (data: Data, size: Int)?
    private var cubeBuilding = false
    private var lastCubeKey: String = ""
    private var lastCubeTime = Date.distantPast

    private var polarizerImage: CIImage?
    private var lastPolarizerTime = Date.distantPast

    private var latestStats: FrameStats?
    var onStats: ((FrameStats) -> Void)?
    var motion: MotionLocation?

    func update(_ c: LiveConfig) {
        lock.lock(); config = c; configVersion += 1; lock.unlock()
    }

    private func currentConfig() -> LiveConfig { lock.lock(); defer { lock.unlock() }; return config }

    /// Framed area in upright normalized coordinates for a given upright image aspect,
    /// narrowed around the centre by any zoom the phone couldn't do itself.
    static func cropRect(imageAspect a: Double, target t: Double, zoom: Double = 1) -> CGRect {
        var w = 1.0, h = 1.0
        if t < a { w = t / a } else { h = a / t }
        let z = max(1, zoom)
        w /= z; h /= z
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    func camera(didOutput pixelBuffer: CVPixelBuffer, depth: AVDepthData?, exposure: PhoneExposure, time: CMTime) {
        frameCount += 1
        let cfg = currentConfig()
        let map = OrientationMap(cfg.display)
        let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
        let uprightAspect = map.swapsAxes ? h / w : w / h
        let crop = LiveProcessor.cropRect(imageAspect: uprightAspect, target: cfg.cropAspect, zoom: cfg.digitalZoom)

        // Measure every other frame.
        if frameCount % 2 == 0 {
            var ac = AnalyzerConfig()
            ac.gains = cfg.look.gains
            ac.bwWeights = cfg.look.bwWeights
            ac.display = cfg.display
            ac.crop = crop
            ac.subjectPoint = cfg.subjectPoint.map { CGPoint(x: crop.minX + $0.x * crop.width, y: crop.minY + $0.y * crop.height) }
            let stats = analyzer.analyze(pixelBuffer, exposure: exposure, config: ac)
            latestStats = stats
            onStats?(stats)
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()]).oriented(map.orientation)
        let ext = image.extent
        let cropRectCI = CGRect(x: ext.minX + crop.minX * ext.width, y: ext.minY + (1 - crop.maxY) * ext.height,
                                width: crop.width * ext.width, height: crop.height * ext.height)
        image = image.cropped(to: cropRectCI)

        if cfg.showFilm, let stats = latestStats {
            // Polarizer: darken polarized blue sky before the film curve.
            if let axis = cfg.polarizerAxis {
                if Date().timeIntervalSince(lastPolarizerTime) > 0.25 {
                    lastPolarizerTime = Date()
                    polarizerImage = makePolarizerImage(stats: stats, cfg: cfg, axis: axis)
                }
                if let pol = polarizerImage {
                    let scaled = pol.transformed(by: CGAffineTransform(scaleX: cropRectCI.width / pol.extent.width,
                                                                       y: cropRectCI.height / pol.extent.height))
                        .transformed(by: CGAffineTransform(translationX: cropRectCI.minX, y: cropRectCI.minY))
                    image = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: scaled])
                        .cropped(to: cropRectCI)
                }
            }

            var look = cfg.look
            let k = cfg.placementEV.map { Float(exposure.ev100 + cfg.calibration - $0) } ?? 0
            look.k = (k * 3).rounded() / 3
            // One range for all three channels keeps the phone's white balance. Levelling each channel on its
            // own swings the colour with whatever happens to be brightest or darkest in the frame.
            if look.mode == .bwNegative {
                look.lo = SIMD3(repeating: stats.loY); look.hi = SIMD3(repeating: stats.hiY)
            } else {
                look.lo = SIMD3(repeating: stats.loL); look.hi = SIMD3(repeating: stats.hiL)
            }
            requestCube(look)
            if let c = currentCube() {
                image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": c.size, "inputCubeData": c.data])
            }
            if cfg.grain > 0.001 { image = Grain.apply(to: image, amount: cfg.grain, seed: frameCount) }
        }

        renderer.setImage(image)
    }

    /// Rebuild the composite film cube when its inputs move enough to matter.
    private func requestCube(_ look: FilmLook) {
        let q: (Float) -> Int = { Int(($0 * 8).rounded()) }
        let key = "\(look.mode)|\(q(look.k))|\(q(look.lo.x))\(q(look.lo.y))\(q(look.lo.z))|\(q(look.hi.x))\(q(look.hi.y))\(q(look.hi.z))|\(look.shadowLimit)|\(look.highlightLimit)|\(look.saturation)|\(look.contrast)|\(look.warmth)|\(look.tint)|\(look.houseLook)|\(look.gains)|\(LookTables.shared.greensShift)"
        cubeLock.lock()
        let busy = cubeBuilding, have = cube != nil, recent = Date().timeIntervalSince(lastCubeTime) < 0.12
        guard key != lastCubeKey, !busy, !(have && recent) else { cubeLock.unlock(); return }
        cubeBuilding = true
        lastCubeKey = key
        cubeLock.unlock()
        cubeQueue.async {
            let size = 25
            let data = FilmPipeline.buildCube(size: size, input: .videoSRGB, look: look)
            self.lockCube { self.cube = (data, size); self.cubeBuilding = false; self.lastCubeTime = Date() }
        }
    }

    private let cubeLock = NSLock()
    private func lockCube(_ f: () -> Void) { cubeLock.lock(); f(); cubeLock.unlock() }
    private func currentCube() -> (data: Data, size: Int)? { cubeLock.lock(); defer { cubeLock.unlock() }; return cube }

    /// Low-resolution multiplier image: 1 where the polarizer has no effect, lower on polarized blue sky.
    private func makePolarizerImage(stats: FrameStats, cfg: LiveConfig, axis: Float) -> CIImage? {
        guard let att = motion?.attitude, att.hasTrueNorth, let sun = motion?.sun(), stats.thumbWidth > 0 else { return nil }
        let grid = SkyGrid.compute(attitude: att, sun: sun, orientation: cfg.display,
                                   tanHalfWidth: cfg.tanHalfWidth, tanHalfHeight: cfg.tanHalfHeight, cols: 16, rows: 16)
        let w = stats.thumbWidth, h = stats.thumbHeight
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = stats.thumb[y * w + x]
                let s = grid.sample(x: (Float(x) + 0.5) / Float(w), y: (Float(y) + 0.5) / Float(h))
                let m = PolarizerModel.multiplier(linear: c, dop: s.dop, angle: s.angle, elevation: s.elevation, axis: axis)
                // The frame is display-encoded, so apply the encoded-space equivalent.
                let enc = powf(m, 1 / 2.2)
                // Bitmap rows run top-down, matching CIImage(bitmapData:).
                let o = (y * w + x) * 4
                px[o] = enc; px[o + 1] = enc; px[o + 2] = enc; px[o + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

enum PolarizerModel {
    /// Multiplier on linear light for one pixel: blue sky above the horizon darkens (or brightens) with the geometry.
    static func multiplier(linear c: SIMD3<Float>, dop: Float, angle: Float, elevation: Float, axis: Float) -> Float {
        let sum = c.x + c.y + c.z
        guard sum > 1e-4 else { return 1 }
        let blueShare = c.z / sum
        var w = max(0, min(1, (blueShare - 0.36) / 0.10))
        if c.z < c.x * 1.05 { w = 0 }
        w *= max(0, min(1, elevation / 4 + 0.5))
        let f = SkyGrid.factor(dop: dop, angle: angle, axis: axis)
        return 1 + w * (f - 1)
    }
}

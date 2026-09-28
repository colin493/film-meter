import AVFoundation
import CoreImage
import UIKit

/// Exposure the phone used for one frame.
struct PhoneExposure: Codable, Hashable {
    var duration: Double
    var iso: Double
    var aperture: Double
    var targetOffset: Double

    /// EV at ISO 100 of the phone's own setting for this frame.
    var ev100: Double { ExposureMath.ev100(aperture: aperture, shutter: duration, iso: iso) }
}

protocol CameraFrameSink: AnyObject {
    func camera(didOutput pixelBuffer: CVPixelBuffer, depth: AVDepthData?, exposure: PhoneExposure, time: CMTime)
}

/// Three frames at different exposures, merged later into one high-dynamic-range still.
struct BracketCapture {
    var frames: [(buffer: CVPixelBuffer, ratio: Double)]
    var depth: AVDepthData?
    var baseExposure: PhoneExposure
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "film.camera.session")
    let videoQueue = DispatchQueue(label: "film.camera.video", qos: .userInitiated)

    private(set) var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?

    weak var sink: CameraFrameSink?

    @Published private(set) var isAuthorized = false
    @Published private(set) var isRunning = false
    @Published private(set) var hasDepth = false
    @Published private(set) var deviceName = ""
    @Published private(set) var horizontalFOV: Double = 70
    @Published private(set) var errorMessage: String?
    /// Camera, video format and depth format in use, for the diagnostics in Settings.
    @Published private(set) var formatSummary = ""

    // Bracket state (touched only on videoQueue)
    private enum BracketStep { case idle, base, waitUnder(CMTime?, Double), waitOver(CMTime?, Double) }
    private var bracketStep: BracketStep = .idle
    private var bracketFrames: [(buffer: CVPixelBuffer, ratio: Double)] = []
    private var bracketDepth: AVDepthData?
    private var bracketBase: PhoneExposure?
    private var bracketCompletion: ((BracketCapture?) -> Void)?
    private var bracketStarted = Date()
    /// Most recent depth map, in case the frame that starts a bracket arrives without one.
    private var lastDepth: AVDepthData?
    private var lastDepthTime = Date.distantPast

    // MARK: Setup

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setAuthorized(true)
            sessionQueue.async { self.configureIfNeeded(); self.session.startRunning(); self.publishRunning() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.setAuthorized(granted)
                if granted { self.sessionQueue.async { self.configureIfNeeded(); self.session.startRunning(); self.publishRunning() } }
            }
        default:
            setAuthorized(false)
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() }; self.publishRunning() }
    }

    private func setAuthorized(_ v: Bool) { DispatchQueue.main.async { self.isAuthorized = v } }
    private func publishRunning() { let r = session.isRunning; DispatchQueue.main.async { self.isRunning = r } }

    private var configured = false

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let types: [AVCaptureDevice.DeviceType] = [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        var chosen: AVCaptureDevice?
        for t in types { if let d = found.first(where: { $0.deviceType == t }) { chosen = d; break } }
        guard let device = chosen ?? AVCaptureDevice.default(for: .video) else {
            DispatchQueue.main.async { self.errorMessage = "No camera available" }
            return
        }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            DispatchQueue.main.async { self.errorMessage = "Camera input failed: \(error.localizedDescription)" }
            session.commitConfiguration()
            return
        }

        let depthFormat = selectFormat(device)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        var depthOK = false
        if depthFormat != nil, session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            depthOutput.alwaysDiscardsLateDepthData = true
            depthOK = depthOutput.connection(with: .depthData) != nil
        }

        do {
            try device.lockForConfiguration()
            if let df = depthFormat, depthOK { device.activeDepthDataFormat = df }
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            if device.activeFormat.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = true }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        } catch {}

        session.commitConfiguration()

        if depthOK {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            sync.setDelegate(self, queue: videoQueue)
            synchronizer = sync
        } else {
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }

        let fov = Double(device.activeFormat.videoFieldOfView)
        let name = device.localizedName
        let vd = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var summary = "\(name), \(vd.width)×\(vd.height), field of view \(Int(fov.rounded()))°"
        if let df = device.activeDepthDataFormat {
            let dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription)
            summary += ", depth \(dd.width)×\(dd.height)" + (depthOK ? "" : " (not streaming)")
        } else {
            summary += ", no depth format"
        }
        DispatchQueue.main.async {
            self.hasDepth = depthOK
            self.deviceName = name
            self.horizontalFOV = fov
            self.formatSummary = summary
        }
    }

    /// Picks a 4:3 format near 1920 wide, preferring one that streams depth. Returns the depth format.
    private func selectFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestDepth: AVCaptureDevice.Format?
        var bestScore = Int.max
        let eightBit: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let w = Int(dims.width), h = Int(dims.height)
            guard w > 0, h > 0, w * 3 == h * 4 else { continue }
            let depths = f.supportedDepthDataFormats.filter {
                let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DepthFloat16
            }
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            var score = abs(w - 1920)
            if depths.isEmpty { score += 100_000 }
            if f.isVideoBinned { score += 500 }
            if !eightBit.contains(sub) { score += 2_000 }
            if score < bestScore {
                bestScore = score
                best = f
                bestDepth = depths.max { a, b in
                    CMVideoFormatDescriptionGetDimensions(a.formatDescription).width < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
                }
            }
        }
        guard let format = best else { return nil }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch { return nil }
        return bestDepth
    }

    // MARK: Controls

    /// Zoom so the framed view matches the lens. `factor` is relative to the widest view of this camera.
    /// Reports the zoom the phone actually applied and the most it allows right now, on the main queue.
    func setZoom(_ factor: Double, completion: ((Double, Double) -> Void)? = nil) {
        sessionQueue.async {
            guard let d = self.device else {
                DispatchQueue.main.async { completion?(1, 1) }
                return
            }
            let maxZ = Double(d.maxAvailableVideoZoomFactor)
            let z = CGFloat(max(Double(d.minAvailableVideoZoomFactor), min(maxZ, factor)))
            if abs(d.videoZoomFactor - z) > 0.01 {
                do { try d.lockForConfiguration(); d.videoZoomFactor = z; d.unlockForConfiguration() } catch {}
            }
            let applied = Double(d.videoZoomFactor)
            DispatchQueue.main.async { completion?(applied, maxZ) }
        }
    }

    /// Point is in sensor coordinates (landscape, home button on the right), 0...1.
    func meter(at point: CGPoint?) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                let p = point ?? CGPoint(x: 0.5, y: 0.5)
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Bracket capture

    func captureBracket(completion: @escaping (BracketCapture?) -> Void) {
        videoQueue.async {
            guard case .idle = self.bracketStep else { return }
            self.bracketFrames = []
            self.bracketDepth = nil
            self.bracketBase = nil
            self.bracketCompletion = completion
            self.bracketStarted = Date()
            self.bracketStep = .base
        }
    }

    private func setCustom(duration: Double, iso: Double, onQueue step: @escaping (CMTime) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { return }
            let f = d.activeFormat
            let minT = CMTimeGetSeconds(f.minExposureDuration), maxT = min(CMTimeGetSeconds(f.maxExposureDuration), 0.25)
            let t = max(minT, min(maxT, duration))
            let i = Float(max(Double(f.minISO), min(Double(f.maxISO), iso)))
            do {
                try d.lockForConfiguration()
                d.setExposureModeCustom(duration: CMTime(seconds: t, preferredTimescale: 1_000_000), iso: i) { sync in
                    self.videoQueue.async { step(sync) }
                }
                d.unlockForConfiguration()
            } catch {
                self.videoQueue.async { step(.invalid) }
            }
        }
    }

    private func restoreAuto() {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    private func finishBracket() {
        let done = bracketCompletion
        bracketCompletion = nil
        bracketStep = .idle
        restoreAuto()
        guard let base = bracketBase, !bracketFrames.isEmpty else {
            DispatchQueue.main.async { done?(nil) }
            return
        }
        let result = BracketCapture(frames: bracketFrames, depth: bracketDepth, baseExposure: base)
        DispatchQueue.main.async { done?(result) }
    }

    /// Runs on videoQueue for every frame.
    private func handleBracket(_ pb: CVPixelBuffer, depth: AVDepthData?, exposure: PhoneExposure, time: CMTime) {
        if case .idle = bracketStep { return }
        if Date().timeIntervalSince(bracketStarted) > 2.5 { finishBracket(); return }
        guard let d = device else { finishBracket(); return }
        let f = d.activeFormat
        switch bracketStep {
        case .idle:
            return
        case .base:
            guard let copy = pb.deepCopy() else { finishBracket(); return }
            bracketFrames.append((copy, 1))
            bracketDepth = depth ?? (Date().timeIntervalSince(lastDepthTime) < 0.5 ? lastDepth : nil)
            bracketBase = exposure
            // Three stops under: shorten the shutter first, then lower ISO.
            let target = exposure.duration * exposure.iso / 8
            let t = max(CMTimeGetSeconds(f.minExposureDuration), exposure.duration / 8)
            let iso = max(Double(f.minISO), target / t)
            let ratio = (t * iso) / (exposure.duration * exposure.iso)
            bracketStep = .waitUnder(nil, ratio)
            setCustom(duration: t, iso: iso) { sync in
                if case .waitUnder(_, let r) = self.bracketStep { self.bracketStep = .waitUnder(sync, r) }
            }
        case .waitUnder(let sync, let ratio):
            guard let s = sync else { return }
            if s.isValid, CMTimeCompare(time, s) < 0 { return }
            if let copy = pb.deepCopy() { bracketFrames.append((copy, exposure.duration * exposure.iso / (bracketBase!.duration * bracketBase!.iso))) }
            _ = ratio
            // Two stops over: raise ISO first, then lengthen the shutter (capped to limit blur).
            let base = bracketBase!
            let iso = min(Double(f.maxISO), base.iso * 4)
            let t = min(1.0 / 15, base.duration * (base.iso * 4) / iso)
            let r = (t * iso) / (base.duration * base.iso)
            bracketStep = .waitOver(nil, r)
            setCustom(duration: t, iso: iso) { sync in
                if case .waitOver(_, let rr) = self.bracketStep { self.bracketStep = .waitOver(sync, rr) }
            }
        case .waitOver(let sync, _):
            guard let s = sync else { return }
            if s.isValid, CMTimeCompare(time, s) < 0 { return }
            if let copy = pb.deepCopy(), let base = bracketBase {
                bracketFrames.append((copy, exposure.duration * exposure.iso / (base.duration * base.iso)))
            }
            finishBracket()
        }
    }

    private func exposureNow() -> PhoneExposure {
        guard let d = device else { return PhoneExposure(duration: 1.0 / 60, iso: 100, aperture: 1.8, targetOffset: 0) }
        return PhoneExposure(duration: CMTimeGetSeconds(d.exposureDuration), iso: Double(d.iso),
                             aperture: Double(d.lensAperture), targetOffset: Double(d.exposureTargetOffset))
    }

    fileprivate func deliver(_ pb: CVPixelBuffer, depth: AVDepthData?, time: CMTime) {
        if let depth { lastDepth = depth; lastDepthTime = Date() }
        let exp = exposureNow()
        handleBracket(pb, depth: depth, exposure: exp, time: time)
        sink?.camera(didOutput: pb, depth: depth, exposure: exp, time: time)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(pb, depth: nil, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

extension CameraController: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let v = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !v.sampleBufferWasDropped, let pb = CMSampleBufferGetImageBuffer(v.sampleBuffer) else { return }
        var depth: AVDepthData?
        if let d = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData, !d.depthDataWasDropped {
            depth = d.depthData
        }
        deliver(pb, depth: depth, time: CMSampleBufferGetPresentationTimeStamp(v.sampleBuffer))
    }
}

extension CVPixelBuffer {
    /// Copy into a fresh buffer so the capture pool can recycle the original.
    func deepCopy() -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(self), h = CVPixelBufferGetHeight(self)
        let fmt = CVPixelBufferGetPixelFormatType(self)
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, fmt, attrs, &out) == kCVReturnSuccess, let dst = out else { return nil }
        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(self), let t = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sRow = CVPixelBufferGetBytesPerRow(self), tRow = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = min(sRow, tRow)
        for y in 0..<h { memcpy(t + y * tRow, s + y * sRow, rowBytes) }
        return dst
    }
}

import AVFoundation
import Combine
import SwiftUI
import UIKit

struct AppSettings: Codable, Equatable {
    var calibrationThirds: Int = 0
    var houseLook: Bool = true
    var showGrain: Bool = true
    var useFeet: Bool = true
    var zebras: Bool = true
    var mode: ExposureMode = .aperturePriority
    var metering: MeteringMode = .matrix
    var subjectZone: Double = 0
    var neutralISO: Double = 400
    var apertures: [String: Double] = [:]
    var shutters: [String: Double] = [:]
    var activeFilters: [String: [String]] = [:]
    var activeCameraID: String?
}

struct Library: Codable {
    var cameras: [CameraBody]
    var filters: [FilterDef]
}

struct OtherReading: Equatable {
    var cameraName: String
    var stockName: String
    var reading: ExposureReading
}

enum ActiveSheet: String, Identifiable {
    case rolls, gear, filters, advisor, settings, loadRoll, lens
    var id: String { rawValue }
}

final class AppModel: ObservableObject {
    @Published var cameras: [CameraBody] {
        didSet {
            saveLibrary()
            // A lens edited in Gear (or a new preview stock) should show straight away.
            if oldValue != cameras { updateZoom() }
        }
    }
    @Published var filters: [FilterDef] { didSet { saveLibrary() } }
    @Published var rolls: [Roll] { didSet { Store.save(rolls, "rolls.json") } }
    @Published var settings: AppSettings {
        didSet {
            Store.save(settings, "settings.json")
            if oldValue.metering != settings.metering || oldValue.activeCameraID != settings.activeCameraID {
                resetMeter()
            }
            refresh()
        }
    }
    @Published var compensation: Double = 0 { didSet { refresh() } }
    /// Subject point in the framed view, normalized, top-left origin.
    @Published var subjectPoint: CGPoint?
    @Published var display: DisplayOrientation = .portrait
    @Published private(set) var stats: FrameStats?
    @Published private(set) var meterResult: MeterResult?
    @Published private(set) var reading: ExposureReading?
    @Published private(set) var other: OtherReading?
    @Published var sheet: ActiveSheet?
    @Published var locked: LockedSession?
    @Published var compositions: [CompositionMeta] = []
    @Published private(set) var zoomNote: String?
    @Published private(set) var isLocking = false
    @Published var toast: String?
    /// Zoom still needed after the phone's own zoom, applied as a centre crop.
    @Published private(set) var digitalZoom: Double = 1
    /// What the phone camera reported, for the diagnostics in Settings.
    @Published private(set) var zoomStatus = ""

    let camera = CameraController()
    let motion = MotionLocation()
    let processor = LiveProcessor()
    private let captureControls = CaptureControls()
    private var cancellables = Set<AnyCancellable>()
    private var lastStatsPublish = Date.distantPast
    private let stabilizer = MeterStabilizer()
    private var meterMemory = MeterMemory()
    /// Smoothed statistics the meter reads (the raw ones in `stats` drive the overlays).
    private var meterStats: FrameStats?

    init() {
        let lib = Store.load(Library.self, "library.json")
        cameras = lib?.cameras ?? GearDefaults.cameras()
        filters = lib?.filters ?? GearDefaults.filters()
        rolls = Store.load([Roll].self, "rolls.json") ?? []
        settings = Store.load(AppSettings.self, "settings.json") ?? AppSettings()
        compositions = Store.listCompositions()
        processor.motion = motion
        camera.sink = processor
        processor.onStats = { [weak self] s in
            DispatchQueue.main.async { self?.receive(s) }
        }
        captureControls.onCompensation = { [weak self] v in self?.compensation = v }
        captureControls.onApertureIndex = { [weak self] i in
            guard let self, let lens = self.activeLens else { return }
            let stops = lens.apertureStops
            if i >= 0 && i < stops.count { self.setAperture(stops[i]) }
        }
        camera.$horizontalFOV.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateZoom() }.store(in: &cancellables)
        camera.$isRunning.receive(on: DispatchQueue.main).sink { [weak self] running in if running { self?.installCaptureControls() } }.store(in: &cancellables)
    }

    private func saveLibrary() { Store.save(Library(cameras: cameras, filters: filters), "library.json") }

    // MARK: Derived state

    var activeCamera: CameraBody {
        if let id = settings.activeCameraID, let c = cameras.first(where: { $0.id.uuidString == id }) { return c }
        return cameras.first ?? GearDefaults.cameras()[0]
    }
    var activeLens: Lens? { activeCamera.selectedLens }
    var calibration: Double { Double(settings.calibrationThirds) / 3 }

    func activeRoll(for cameraID: UUID) -> Roll? { rolls.last { $0.cameraID == cameraID && $0.isActive } }

    /// Stock for a body: its loaded roll, else its preview choice ("none" = no film simulation).
    func stock(for cam: CameraBody) -> FilmStock? {
        if let r = activeRoll(for: cam.id) { return r.stock }
        return StockLibrary.stock(cam.previewStockID)
    }

    func push(for cam: CameraBody) -> Double { activeRoll(for: cam.id)?.pushStops ?? 0 }

    func filmISO(for cam: CameraBody) -> Double { stock(for: cam)?.iso ?? settings.neutralISO }

    func activeFilters(for cam: CameraBody) -> [FilterDef] {
        let ids = settings.activeFilters[cam.id.uuidString] ?? []
        return filters.filter { ids.contains($0.id.uuidString) }
    }

    func aperture(for cam: CameraBody) -> Double {
        if let a = settings.apertures[cam.id.uuidString] { return a }
        guard let lens = cam.selectedLens else { return 8 }
        return ExposureMath.nearest(8, in: lens.apertureStops)
    }

    func shutter(for cam: CameraBody) -> Double { settings.shutters[cam.id.uuidString] ?? 1.0 / 125 }

    func setAperture(_ a: Double) { settings.apertures[activeCamera.id.uuidString] = a }
    func setShutter(_ t: Double) { settings.shutters[activeCamera.id.uuidString] = t }

    var cropAspect: Double {
        let f = activeCamera.format
        if f.isSquare { return 1 }
        return display.isLandscape ? f.aspect : 1 / f.aspect
    }

    // MARK: Lifecycle

    func start() {
        camera.start()
        motion.start()
        updateOrientation()
        updateZoom()
        refresh()
    }

    func updateOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let o = scene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let d: DisplayOrientation
        switch o {
        case .landscapeLeft: d = .landscapeLeft
        case .landscapeRight: d = .landscapeRight
        case .portraitUpsideDown: d = .portraitUpsideDown
        default: d = .portrait
        }
        if d != display { display = d; resetMeter(); refresh() }
    }

    /// Match the phone's view to the lens on this format.
    func updateZoom() {
        guard let lens = activeLens else { return }
        let fmt = activeCamera.format
        let tanH = tan(camera.horizontalFOV * .pi / 360)
        let zoom: Double
        if fmt.aspect >= 4.0 / 3.0 { zoom = tanH * 2 * lens.focalLength / fmt.size.long }
        else { zoom = tanH * 0.75 * 2 * lens.focalLength / fmt.size.short }
        zoomNote = zoom < 0.98 ? "The \(Int(lens.focalLength))mm sees wider than this phone camera" : nil
        let want = max(1, zoom)
        camera.setZoom(want) { [weak self] applied, maxZoom in
            guard let self else { return }
            // The phone caps zoom while it streams depth; crop whatever it couldn't do.
            self.digitalZoom = max(1, want / max(1, applied))
            self.zoomStatus = String(format: "Lens needs %.2f×, phone zoom %.2f× (max %.2f×), crop %.2f×", want, applied, maxZoom, self.digitalZoom)
            self.pushConfig()
        }
        refresh()
    }

    /// Tangent of half the framed field of view along the upright width and height.
    private var framedTangents: (w: Double, h: Double) {
        guard let lens = activeLens else { return (0.4, 0.6) }
        let fmt = activeCamera.format
        let f = lens.focalLength
        var longT = fmt.size.long / (2 * f), shortT = fmt.size.short / (2 * f)
        let tanH = tan(camera.horizontalFOV * .pi / 360)
        if longT > tanH { longT = tanH; shortT = tanH / fmt.aspect }
        if fmt.isSquare { return (shortT, shortT) }
        return display.isLandscape ? (longT, shortT) : (shortT, longT)
    }

    func selectCamera(_ id: UUID) {
        settings.activeCameraID = id.uuidString
        subjectPoint = nil
        updateZoom()
        installCaptureControls()
    }

    func selectLens(_ id: UUID) {
        guard let i = cameras.firstIndex(where: { $0.id == activeCamera.id }) else { return }
        cameras[i].selectedLensID = id
        resetMeter()
        updateZoom()
        installCaptureControls()
    }

    func installCaptureControls() {
        guard let lens = activeLens else { return }
        let stops = lens.apertureStops
        let titles = stops.map { "f/" + ExposureMath.formatAperture($0) }
        let current = aperture(for: activeCamera)
        let idx = stops.firstIndex(where: { abs($0 - current) < 0.05 }) ?? 0
        let comp = compensation
        let session = camera.session
        camera.videoQueue.async { [captureControls] in
            captureControls.install(on: session, compensation: comp, apertureTitles: titles, apertureIndex: idx)
        }
    }

    // MARK: Metering

    private func receive(_ s: FrameStats) {
        // UI updates at ~10 Hz is plenty.
        if Date().timeIntervalSince(lastStatsPublish) < 0.09 { return }
        lastStatsPublish = Date()
        stats = s
        meterStats = stabilizer.update(s)
        refresh(newFrame: true)
    }

    /// Start the meter fresh: new camera, lens, orientation or metering mode.
    private func resetMeter() {
        stabilizer.reset()
        meterMemory.reset()
        meterStats = stats
    }

    /// The framed area within the full upright camera image (normalized).
    var uprightCrop: CGRect {
        let map = OrientationMap(display)
        var w = 1920.0, h = 1440.0
        if let d = camera.device {
            let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
            if dims.width > 0 && dims.height > 0 { w = Double(dims.width); h = Double(dims.height) }
        }
        return LiveProcessor.cropRect(imageAspect: map.swapsAxes ? h / w : w / h, target: cropAspect, zoom: digitalZoom)
    }

    func tapSubject(_ p: CGPoint) {
        subjectPoint = p
        stabilizer.resetSubject()
        meterMemory.placementThirds = nil
        if settings.metering != .subject { settings.metering = .subject }
        // Framed point → upright image point → sensor point for the phone's own metering.
        let crop = uprightCrop
        let up = CGPoint(x: crop.minX + p.x * crop.width, y: crop.minY + p.y * crop.height)
        camera.meter(at: OrientationMap(display).toSensor(up))
        refresh()
    }

    func clearSubject() {
        subjectPoint = nil
        stabilizer.resetSubject()
        meterMemory.placementThirds = nil
        camera.meter(at: nil)
        refresh()
    }

    func refresh(newFrame: Bool = false) {
        let cam = activeCamera
        let st = stock(for: cam)
        if let s = meterStats {
            let result = Meter.evaluate(stats: s, mode: settings.metering, zone: settings.subjectZone, stock: st,
                                        pushStops: push(for: cam), calibration: calibration, sun: motion.sun(),
                                        attitude: motion.attitude, display: display,
                                        memory: &meterMemory, newFrame: newFrame)
            meterResult = result
            reading = solve(for: cam, placementEV: result.placementEV, primary: true)
            if let otherCam = cameras.first(where: { $0.id != cam.id }), let r = solve(for: otherCam, placementEV: result.placementEV, primary: false) {
                other = OtherReading(cameraName: otherCam.name, stockName: stock(for: otherCam)?.name ?? "No stock", reading: r)
            } else {
                other = nil
            }
        }
        pushConfig()
    }

    func solve(for cam: CameraBody, placementEV: Double, primary: Bool) -> ExposureReading? {
        guard let lens = cam.selectedLens else { return nil }
        let st = stock(for: cam)
        let inputs = ExposureInputs(sceneEV100: placementEV, filmISO: filmISO(for: cam), pushStops: push(for: cam),
                                    filterStops: activeFilters(for: cam).reduce(0) { $0 + $1.factorStops },
                                    compensation: primary ? compensation : 0,
                                    mode: primary ? settings.mode : .aperturePriority,
                                    aperture: aperture(for: cam), shutter: shutter(for: cam), body: cam, lens: lens,
                                    reciprocity: st?.reciprocity)
        return ExposureSolver.solve(inputs)
    }

    /// EV100 that lands on the film's middle grey with the current settings.
    var filmPlacementEV: Double? {
        guard let m = meterResult, let r = reading else { return nil }
        return m.placementEV - compensation - r.residual
    }

    private func pushConfig() {
        let cam = activeCamera
        let st = stock(for: cam)
        var c = LiveConfig()
        c.look = FilmLook.make(stock: st, pushStops: push(for: cam), filters: activeFilters(for: cam), houseLook: settings.houseLook)
        c.showFilm = true
        c.placementEV = filmPlacementEV
        c.calibration = calibration
        c.display = display
        c.cropAspect = cropAspect
        c.subjectPoint = settings.metering == .subject ? subjectPoint : nil
        let extra = compensation + (reading?.residual ?? 0)
        c.grain = settings.showGrain ? Grain.amount(stock: st, format: cam.format, pushStops: push(for: cam), underexposure: max(0, -extra)) : 0
        let pol = activeFilters(for: cam).contains { $0.isPolarizer }
        c.polarizerAxis = pol ? PolarizerAxis.angle(format: cam.format, orientation: display) : nil
        let t = framedTangents
        c.tanHalfWidth = t.w; c.tanHalfHeight = t.h
        c.digitalZoom = digitalZoom
        processor.update(c)
    }

    // MARK: Filters, rolls, logging

    func toggleFilter(_ f: FilterDef) {
        let key = activeCamera.id.uuidString
        var ids = settings.activeFilters[key] ?? []
        if let i = ids.firstIndex(of: f.id.uuidString) { ids.remove(at: i) } else { ids.append(f.id.uuidString) }
        settings.activeFilters[key] = ids
    }

    func loadRoll(camera cam: CameraBody, stockID: String, push: Double, capacity: Int) {
        for i in rolls.indices where rolls[i].cameraID == cam.id && rolls[i].isActive { rolls[i].finishedAt = Date() }
        rolls.append(Roll(cameraID: cam.id, stockID: stockID, pushStops: push, capacity: capacity, loadedAt: Date()))
        refresh()
    }

    func finishRoll(_ id: UUID) {
        if let i = rolls.firstIndex(where: { $0.id == id }) { rolls[i].finishedAt = Date() }
        refresh()
    }

    func deleteRoll(_ id: UUID) {
        rolls.removeAll { $0.id == id }
        refresh()
    }

    @discardableResult
    func logFrame(compositionID: UUID? = nil, aperture: Double? = nil, shutter: Double? = nil, note: String? = nil) -> Int? {
        let cam = activeCamera
        guard let idx = rolls.lastIndex(where: { $0.cameraID == cam.id && $0.isActive }) else {
            toast = "Load a roll in the \(cam.name) first"
            return nil
        }
        guard let r = reading, let lens = activeLens else { return nil }
        let number = rolls[idx].nextFrame
        let loc = motion.coordinate
        let recip = r.reciprocity.map { "Metered \(ExposureMath.formatShutter($0.metered)), shoot \(ExposureMath.formatShutter($0.corrected))" }
        let log = FrameLog(number: number, date: Date(), latitude: loc?.latitude, longitude: loc?.longitude,
                           lensName: lens.label, aperture: aperture ?? r.aperture, shutter: shutter ?? r.shutter,
                           reciprocityNote: recip, sceneEV100: meterResult?.placementEV ?? 0, mode: settings.mode.rawValue,
                           metering: settings.metering.rawValue, filters: activeFilters(for: cam).map(\.name),
                           compositionID: compositionID, note: note ?? "")
        rolls[idx].frames.append(log)
        if number >= rolls[idx].capacity { toast = "Last frame on this roll" } else { toast = "Logged frame \(number)" }
        return number
    }

    // MARK: Lock

    func lock() {
        guard !isLocking, locked == nil, let m = meterResult, let r = reading, let placement = filmPlacementEV, let lens = activeLens else { return }
        isLocking = true
        let cam = activeCamera
        let st = stock(for: cam)
        let push = self.push(for: cam)
        let fl = activeFilters(for: cam)
        let display = self.display
        let aspect = cropAspect
        let zoom = digitalZoom
        let tangents = framedTangents
        let subject = subjectPoint
        let sun = motion.sun()
        let att = motion.attitude
        let loc = motion.coordinate
        let calib = calibration
        let comp = compensation
        let iso = filmISO(for: cam)
        let roll = activeRoll(for: cam.id)
        camera.captureBracket { [weak self] capture in
            guard let self else { return }
            guard let capture else { self.isLocking = false; self.toast = "Couldn't lock the frame"; return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let built = StillBuilder.build(capture: capture, display: display, cropAspect: aspect, zoom: zoom) else {
                    DispatchQueue.main.async { self.isLocking = false; self.toast = "Couldn't lock the frame" }
                    return
                }
                var sky: SkyGrid?
                if let att, att.hasTrueNorth, let sun {
                    sky = SkyGrid.compute(attitude: att, sun: sun, orientation: display, tanHalfWidth: tangents.w, tanHalfHeight: tangents.h)
                }
                let meta = CompositionMeta(date: Date(), cameraID: cam.id, cameraName: cam.name, lensName: lens.label,
                                           focalLength: lens.focalLength, format: cam.format, stockID: st?.id, pushStops: push,
                                           filterNames: fl.map(\.name), filterIDs: fl.map(\.id), placementEV: placement,
                                           meterEV: m.placementEV, compensation: comp, filmISO: iso,
                                           baseEV100: capture.baseExposure.ev100 + calib, aperture: r.aperture, shutter: r.shutter,
                                           focusM: nil, display: display, width: built.width, height: built.height,
                                           depthWidth: built.depthWidth, depthHeight: built.depthHeight,
                                           latitude: loc?.latitude, longitude: loc?.longitude, sun: sun, sky: sky,
                                           rollID: roll?.id, frameNumber: nil)
                let frame = LockedFrame(meta: meta, width: built.width, height: built.height, linear: built.linear, depth: built.depth)
                let p = subject ?? CGPoint(x: 0.5, y: 0.5)
                if let d = frame.depthAt(x: Float(p.x), y: Float(p.y)) { frame.meta.focusM = Double(d) }
                DispatchQueue.main.async {
                    self.isLocking = false
                    self.locked = LockedSession(frame: frame, model: self, fromLibrary: false)
                }
            }
        }
    }

    func openComposition(_ meta: CompositionMeta) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let frame = Store.loadComposition(meta) else {
                DispatchQueue.main.async { self.toast = "Couldn't open that composition" }
                return
            }
            DispatchQueue.main.async {
                self.sheet = nil
                self.locked = LockedSession(frame: frame, model: self, fromLibrary: true)
            }
        }
    }

    func deleteComposition(_ meta: CompositionMeta) {
        Store.deleteComposition(meta.id)
        compositions.removeAll { $0.id == meta.id }
    }

    /// Filters for a saved or locked frame, looked up by id.
    func filters(ids: [UUID]) -> [FilterDef] { filters.filter { ids.contains($0.id) } }
}

import SwiftUI
import UIKit

/// State for a locked frame: re-renders as the exposure and aperture sliders move.
final class LockedSession: ObservableObject, Identifiable {
    let id = UUID()
    let frame: LockedFrame
    let fromLibrary: Bool
    private let renderer: StillRenderer
    private weak var model: AppModel?
    private let queue = DispatchQueue(label: "film.still.render", qos: .userInitiated)
    private var pending: StillParams?
    private var busy = false

    @Published var exposureShift: Double = 0 { didSet { schedule() } }
    @Published var aperture: Double { didSet { schedule() } }
    @Published var focusM: Double? { didSet { schedule() } }
    @Published var showZebras: Bool { didSet { schedule() } }
    @Published private(set) var image: CGImage?
    @Published private(set) var zebra: CGImage?
    @Published private(set) var stats = StillStats()
    @Published private(set) var saved = false

    let stock: FilmStock?
    let lensStops: [Double]
    let body: CameraBody?
    let filters: [FilterDef]

    init(frame: LockedFrame, model: AppModel, fromLibrary: Bool) {
        self.frame = frame
        self.fromLibrary = fromLibrary
        self.model = model
        self.renderer = StillRenderer(frame: frame)
        self.stock = StockLibrary.stock(frame.meta.stockID)
        let body = model.cameras.first { $0.id == frame.meta.cameraID }
        self.body = body
        let lens = body?.lenses.first { $0.label == frame.meta.lensName } ?? body?.selectedLens
        self.lensStops = lens?.apertureStops ?? ExposureMath.halfApertures.filter { $0 >= 2 && $0 <= 22 }
        self.filters = model.filters(ids: frame.meta.filterIDs)
        self.aperture = frame.meta.aperture
        self.focusM = frame.meta.focusM
        self.showZebras = model.settings.zebras
        schedule()
    }

    var params: StillParams {
        var p = StillParams()
        p.exposureShift = exposureShift
        p.aperture = aperture
        p.focusM = focusM
        p.gains = FilmLook.colourGains(filters)
        let hasPol = filters.contains { $0.isPolarizer }
        p.polarizerAxis = hasPol ? PolarizerAxis.angle(format: frame.meta.format, orientation: frame.meta.display) : nil
        p.look = FilmLook.make(stock: stock, pushStops: frame.meta.pushStops, filters: filters, houseLook: model?.settings.houseLook ?? true)
        let showGrain = model?.settings.showGrain ?? true
        p.grain = showGrain ? Grain.amount(stock: stock, format: frame.meta.format, pushStops: frame.meta.pushStops,
                                           underexposure: max(0, -(frame.meta.compensation + exposureShift))) : 0
        p.showZebras = showZebras
        return p
    }

    /// Readout for the current slider positions (aperture priority on the locked frame).
    var reading: ExposureReading? {
        guard let body, let lens = body.lenses.first(where: { $0.label == frame.meta.lensName }) ?? body.selectedLens else { return nil }
        let filterStops = filters.reduce(0) { $0 + $1.factorStops }
        return ExposureSolver.solve(ExposureInputs(sceneEV100: frame.meta.meterEV, filmISO: frame.meta.filmISO,
                                                   pushStops: frame.meta.pushStops, filterStops: filterStops,
                                                   compensation: frame.meta.compensation + exposureShift,
                                                   mode: .aperturePriority, aperture: aperture, shutter: frame.meta.shutter,
                                                   body: body, lens: lens, reciprocity: stock?.reciprocity))
    }

    var dofLimits: (near: Double, far: Double, hyperfocal: Double)? {
        guard let f = focusM else { return nil }
        let c = frame.meta.format.circleOfConfusion
        let lim = DepthOfField.limits(focalMM: frame.meta.focalLength, aperture: aperture, cocMM: c, focusM: f)
        return (lim.near, lim.far, DepthOfField.hyperfocalM(focalMM: frame.meta.focalLength, aperture: aperture, cocMM: c))
    }

    func focus(at p: CGPoint) {
        if let d = frame.depthAt(x: Float(p.x), y: Float(p.y)) { focusM = Double(d) }
    }

    private func schedule() {
        let p = params
        queue.async {
            if self.busy { self.pending = p; return }
            self.busy = true
            var next: StillParams? = p
            while let job = next {
                let out = self.renderer.render(job)
                DispatchQueue.main.async {
                    self.image = out.image
                    self.zebra = out.zebra
                    self.stats = out.stats
                }
                next = self.pending
                self.pending = nil
            }
            self.busy = false
        }
    }

    /// Save for later, optionally logging it as the next frame on the roll.
    func save(logFrame: Bool) {
        guard let model else { return }
        var number: Int?
        if logFrame, let r = reading {
            number = model.logFrame(compositionID: frame.id, aperture: r.aperture, shutter: r.shutter, note: "From a saved composition")
        }
        frame.meta.frameNumber = number
        frame.meta.aperture = aperture
        frame.meta.focusM = focusM
        let preview = image
        let meta = frame.meta
        DispatchQueue.global(qos: .utility).async {
            do {
                try Store.saveComposition(self.frame, preview: preview)
                DispatchQueue.main.async {
                    model.compositions.removeAll { $0.id == meta.id }
                    model.compositions.insert(meta, at: 0)
                    self.saved = true
                    model.toast = number.map { "Saved as frame \($0)" } ?? "Saved"
                }
            } catch {
                DispatchQueue.main.async { model.toast = "Couldn't save: \(error.localizedDescription)" }
            }
        }
    }
}

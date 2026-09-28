import SwiftUI

/// Side feature: which stock (and which loaded camera) suits the scene in front of you.
struct AdvisorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    struct Loaded: Identifiable {
        let id: UUID
        let camera: CameraBody
        let stock: FilmStock
    }

    struct Pick: Identifiable {
        let id: String
        let stock: FilmStock
        let score: Double
        let lines: [String]
    }

    var body: some View {
        NavigationStack {
            List {
                if let m = model.meterResult, let lens = model.activeLens {
                    Section {
                        LabeledContent("Light", value: ExposureMath.formatEV(m.placementEV))
                        LabeledContent("Scene range", value: ExposureMath.formatStops(m.sceneRange, signed: false) + " stops" + (m.phoneClipped ? " or more" : ""))
                    } footer: {
                        Text("Range is what the phone can see; bright highlights may extend past it.")
                    }
                    let loaded = model.cameras.compactMap { cam -> Loaded? in
                        guard let s = model.activeRoll(for: cam.id)?.stock else { return nil }
                        return Loaded(id: cam.id, camera: cam, stock: s)
                    }
                    if loaded.count > 1 {
                        Section("Loaded now") {
                            ForEach(loaded) { pair in
                                let p = evaluate(pair.stock, ev: m.placementEV, range: m.sceneRange, clipped: m.phoneClipped,
                                                 lens: pair.camera.selectedLens ?? lens, body: pair.camera)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(pair.camera.name): \(pair.stock.name)").font(.subheadline.weight(.medium))
                                    ForEach(p.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.dim) }
                                }
                            }
                        }
                    }
                    Section("Best stocks for this scene") {
                        ForEach(rank(ev: m.placementEV, range: m.sceneRange, clipped: m.phoneClipped, lens: lens).prefix(8)) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.stock.name).font(.subheadline.weight(.medium))
                                ForEach(p.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.dim) }
                            }
                        }
                    }
                } else {
                    Text("Point the camera at the scene first.").foregroundStyle(Theme.dim)
                }
            }
            .navigationTitle("Stock advisor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Scores are compared in half-point steps and ties keep the library's order, so near-equal
    /// stocks don't trade places with every small change in the light.
    private func rank(ev: Double, range: Double, clipped: Bool, lens: Lens) -> [Pick] {
        var order: [String: Int] = [:]
        for (i, s) in StockLibrary.all.enumerated() { order[s.id] = i }
        return StockLibrary.all.map { evaluate($0, ev: ev, range: range, clipped: clipped, lens: lens, body: model.activeCamera) }
            .sorted { a, b in
                let sa = (a.score * 2).rounded(), sb = (b.score * 2).rounded()
                if sa != sb { return sa > sb }
                return (order[a.id] ?? 0) < (order[b.id] ?? 0)
            }
    }

    private func evaluate(_ s: FilmStock, ev: Double, range: Double, clipped: Bool, lens: Lens, body: CameraBody) -> Pick {
        var score = 0.0
        var lines: [String] = []
        // Latitude against scene range.
        let latitude = s.highlightLimit - s.shadowLimit
        let sceneRange = range + (clipped ? 2 : 0)
        let margin = latitude - sceneRange
        if margin >= 1 {
            score += 2
            let spare = Int(margin.rounded(.down))
            lines.append("Holds the scene with \(spare) \(spare == 1 ? "stop" : "stops") to spare")
        } else if margin >= 0 {
            score += 1
            lines.append("Just holds the scene's range")
        } else {
            score -= 2 + (-margin)
            lines.append("Scene is \(ExposureMath.formatStops(-margin, signed: false)) stops past its range")
        }
        // Handheld at the widest aperture.
        let target = ev + log2(s.iso / 100)
        let t = ExposureMath.nominalShutter(ExposureMath.shutter(forEV: target, aperture: lens.maxAperture))
        let limit = min(1.0 / 30, 1 / lens.focalLength)
        if t <= limit {
            score += 2
            let n = ExposureMath.aperture(forEV: target, shutter: max(1 / lens.focalLength, body.fastestShutter * 2))
            lines.append("Handheld: \(ExposureMath.formatShutter(t)) wide open, or f/\(ExposureMath.formatAperture(ExposureMath.nearest(n, in: lens.apertureStops))) at \(ExposureMath.formatShutter(max(1 / lens.focalLength, body.fastestShutter * 2)))")
        } else {
            score -= min(4, log2(t / limit))
            lines.append("Needs \(ExposureMath.formatShutter(t)) wide open: tripod or push")
        }
        if t < body.fastestShutter { score -= 1; lines.append("Too bright wide open for this shutter; stop down") }
        // Slide film wants little contrast; fast film costs grain in good light.
        if s.kind == .slide && sceneRange > 5 { score -= 1.5 }
        if ev > 12 && s.iso >= 800 { score -= 0.5 }
        return Pick(id: s.id, stock: s, score: score, lines: lines)
    }
}

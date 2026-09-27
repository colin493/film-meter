import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool

    var body: some View {
        let cam = model.activeCamera
        let lens = cam.selectedLens
        let r = model.reading
        VStack(spacing: 10) {
            // Mode and metering
            HStack(spacing: 8) {
                Picker("Mode", selection: $model.settings.mode) {
                    ForEach(ExposureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                Picker("Metering", selection: $model.settings.metering) {
                    ForEach(MeteringMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            // Readout
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(r.map { "f/" + ExposureMath.formatAperture($0.aperture) } ?? "f/–")
                    .font(.system(size: compact ? 30 : 38, weight: .bold, design: .rounded).monospacedDigit())
                Text(r.map { shutterText($0) } ?? "–")
                    .font(.system(size: compact ? 30 : 38, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(r?.reciprocity != nil ? Theme.accent : .white)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    if let m = model.meterResult { Text(ExposureMath.formatEV(m.placementEV)).font(.caption.monospacedDigit()) }
                    Text("EI \(Int((r?.effectiveISO ?? model.filmISO(for: cam)).rounded()))").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)

            if model.settings.mode == .manual, let r {
                MeterNeedle(stops: r.needle)
            }

            // Why the meter chose what it did, and anything to watch for.
            VStack(alignment: .leading, spacing: 3) {
                if let m = model.meterResult { Text(m.reason).font(.footnote).foregroundStyle(Theme.dim) }
                if let rec = r?.reciprocity {
                    Text(reciprocityText(rec)).font(.footnote).foregroundStyle(Theme.accent)
                }
                ForEach(r?.warnings ?? [], id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Dials
            if let lens {
                HStack(spacing: 8) {
                    StepDial(title: "Aperture", values: lens.apertureStops, format: { "f/" + ExposureMath.formatAperture($0) },
                             value: Binding(get: { model.aperture(for: cam) }, set: { model.setAperture($0) }),
                             enabled: model.settings.mode != .shutterPriority)
                    StepDial(title: "Shutter", values: cam.shutterSpeeds, format: ExposureMath.formatShutter,
                             value: Binding(get: { model.shutter(for: cam) }, set: { model.setShutter($0) }),
                             enabled: model.settings.mode != .aperturePriority)
                }
            }
            HStack(spacing: 8) {
                StepDial(title: "Compensation", values: stride(from: -3.0, through: 3.0, by: 1.0 / 3.0).map { ($0 * 3).rounded() / 3 },
                         format: { ExposureMath.formatStops($0) }, value: $model.compensation,
                         highlight: model.compensation != 0)
                if model.settings.metering == .subject {
                    StepDial(title: "Place subject", values: stride(from: -2.0, through: 2.0, by: 1.0 / 3.0).map { ($0 * 3).rounded() / 3 },
                             format: { zoneLabel($0) }, value: $model.settings.subjectZone,
                             highlight: model.settings.subjectZone != 0)
                }
            }

            // Actions
            HStack(spacing: 10) {
                ActionButton(icon: "camera.filters", title: filterTitle) { model.sheet = .filters }
                ActionButton(icon: "square.and.pencil", title: "Log frame") { model.logFrame() }
                Button {
                    model.lock()
                } label: {
                    ZStack {
                        Circle().fill(Theme.accent).frame(width: 64, height: 64)
                        Image(systemName: "lock.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .accessibilityLabel("Lock frame")
                ActionButton(icon: "wand.and.stars", title: "Stocks") { model.sheet = .advisor }
                ActionButton(icon: "books.vertical", title: "Rolls") { model.sheet = .rolls }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, compact ? 12 : 6)
    }

    private var filterTitle: String {
        let fs = model.activeFilters(for: model.activeCamera)
        if fs.isEmpty { return "Filters" }
        let stops = fs.reduce(0) { $0 + $1.factorStops }
        return "\(fs.count) · \(ExposureMath.formatStops(stops))"
    }

    private func shutterText(_ r: ExposureReading) -> String {
        if r.usesBulb { return "B " + ExposureMath.formatShutter(r.shutter) }
        return ExposureMath.formatShutter(r.shutter)
    }

    private func reciprocityText(_ rec: ReciprocityResult) -> String {
        if rec.notRecommended { return "Beyond the data sheet's limit. \(rec.note)" }
        var s = "Reciprocity: metered \(ExposureMath.formatShutter(rec.metered)), shoot \(ExposureMath.formatShutter(rec.corrected))"
        if rec.isEstimate { s += " (estimate)" }
        return s
    }

    private func zoneLabel(_ z: Double) -> String {
        let zones = ["III", "III½", "IV", "IV½", "V", "V½", "VI", "VI½", "VII"]
        let idx = Int(((z + 2) * 2).rounded())
        if abs(z * 2 - (z * 2).rounded()) < 0.01, idx >= 0, idx < zones.count { return "Zone " + zones[idx] }
        return ExposureMath.formatStops(z)
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.white)
    }
}

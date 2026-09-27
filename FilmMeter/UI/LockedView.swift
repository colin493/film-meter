import SwiftUI

struct LockedView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: LockedSession

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 8) {
                    header
                    HStack(spacing: 6) {
                        VerticalSlider(value: $session.exposureShift, range: -3...3, step: 1.0 / 3.0, label: "Exposure",
                                       format: { ExposureMath.formatStops($0) })
                        imageArea
                        VerticalSlider(value: apertureIndex, range: 0...Double(max(1, session.lensStops.count - 1)), step: 1,
                                       label: "Aperture", format: { i in
                                           let idx = max(0, min(session.lensStops.count - 1, Int(i.rounded())))
                                           return session.lensStops.isEmpty ? "–" : "f/" + ExposureMath.formatAperture(session.lensStops[idx])
                                       })
                    }
                    .frame(maxHeight: .infinity)
                    readout(landscape: landscape)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                ToastView()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    private var header: some View {
        HStack {
            Button {
                model.locked = nil
            } label: {
                Label("Back", systemImage: "chevron.down").labelStyle(.titleAndIcon)
            }
            Spacer()
            VStack(spacing: 0) {
                Text(session.stock?.name ?? "No stock").font(.subheadline.weight(.semibold))
                Text("\(session.frame.meta.cameraName) · \(session.frame.meta.lensName)").font(.caption2).foregroundStyle(Theme.dim)
            }
            Spacer()
            Menu {
                Button { session.save(logFrame: false) } label: { Label("Save composition", systemImage: "square.and.arrow.down") }
                Button { session.save(logFrame: true) } label: { Label("Save and log as next frame", systemImage: "film") }
                Toggle(isOn: $session.showZebras) { Label("Clipping stripes", systemImage: "line.diagonal") }
            } label: {
                Image(systemName: session.saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 20)).padding(6)
            }
        }
        .padding(.horizontal, 6)
    }

    private var imageArea: some View {
        GeometryReader { geo in
            let aspect = Double(session.frame.width) / Double(max(1, session.frame.height))
            let rect = ViewfinderView.fit(aspect: aspect, in: geo.size)
            ZStack(alignment: .topLeading) {
                if let img = session.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    ProgressView().frame(width: geo.size.width, height: geo.size.height)
                }
                if session.showZebras, let z = session.zebra {
                    Image(decorative: z, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                let p = v.location
                guard rect.contains(p), session.frame.hasDepth else { return }
                session.focus(at: CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
            })
        }
    }

    private var apertureIndex: Binding<Double> {
        Binding(get: {
            let stops = session.lensStops
            let i = stops.indices.min { abs(log2(stops[$0] / session.aperture)) < abs(log2(stops[$1] / session.aperture)) } ?? 0
            return Double(i)
        }, set: { v in
            let stops = session.lensStops
            guard !stops.isEmpty else { return }
            let i = max(0, min(stops.count - 1, Int(v.rounded())))
            session.aperture = stops[i]
        })
    }

    private func readout(landscape: Bool) -> some View {
        let r = session.reading
        let feet = model.settings.useFeet
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(r.map { "f/" + ExposureMath.formatAperture($0.aperture) } ?? "f/–")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                Text(r.map { ($0.usesBulb ? "B " : "") + ExposureMath.formatShutter($0.shutter) } ?? "–")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(r?.reciprocity != nil ? Theme.accent : .white)
                Spacer()
                if session.exposureShift != 0 {
                    Text(ExposureMath.formatStops(session.exposureShift) + " vs meter").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            if let rec = r?.reciprocity, rec.needsCorrection {
                Text("Reciprocity: metered \(ExposureMath.formatShutter(rec.metered)), shoot \(ExposureMath.formatShutter(rec.corrected))\(rec.isEstimate ? " (estimate)" : "")")
                    .font(.footnote).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 14) {
                if let d = session.dofLimits, let f = session.focusM {
                    Label("Focus \(ExposureMath.formatDistance(f, feet: feet))", systemImage: "scope")
                    Text("Sharp \(ExposureMath.formatDistance(d.near, feet: feet))–\(ExposureMath.formatDistance(d.far, feet: feet))")
                } else if !session.frame.hasDepth {
                    Text("No depth captured: blur preview off")
                }
            }
            .font(.footnote).foregroundStyle(Theme.dim)
            if session.showZebras, session.stock != nil {
                HStack(spacing: 12) {
                    legend(color: Color(red: 0.9, green: 0.16, blue: 0.16), text: "Highlights past the stock's limit \(pct(session.stats.highlightClip))")
                    legend(color: Color(red: 0.16, green: 0.43, blue: 0.9), text: "Shadows lost \(pct(session.stats.shadowClip))")
                }
                .font(.caption2)
            }
            if session.frame.hasDepth {
                Text("Tap the image to set focus. Blur is simulated from the phone's depth map.").font(.caption2).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, landscape ? 2 : 8)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(text).foregroundStyle(Theme.dim)
        }
    }

    private func pct(_ f: Float) -> String {
        if f <= 0 { return "" }
        return f < 0.01 ? "(<1%)" : "(\(Int((f * 100).rounded()))%)"
    }
}

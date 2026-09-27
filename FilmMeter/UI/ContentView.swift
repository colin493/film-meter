import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    HStack(spacing: 0) {
                        ViewfinderView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 0) {
                            TopBar(compact: true)
                            ScrollView { ControlPanel(compact: true) }
                        }
                        .frame(width: min(380, geo.size.width * 0.44))
                        .background(Theme.panel)
                    }
                } else {
                    VStack(spacing: 0) {
                        TopBar(compact: false)
                        ViewfinderView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ControlPanel(compact: false)
                            .background(Theme.panel)
                    }
                }
                ToastView()
                if model.isLocking {
                    ProgressView("Locking…")
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: landscape) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.updateOrientation() }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onCameraCaptureEvent { event in
            if event.phase == .ended { model.lock() }
        }
        .fullScreenCover(item: $model.locked) { session in
            LockedView(session: session).environmentObject(model)
        }
        .sheet(item: $model.sheet) { sheet in
            sheetView(sheet).environmentObject(model).preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .rolls: RollsView()
        case .loadRoll: LoadRollView(cameraID: model.activeCamera.id)
        case .gear: GearView()
        case .filters: FiltersSheet()
        case .advisor: AdvisorView()
        case .settings: SettingsView()
        case .lens: LensPickerSheet()
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool

    var body: some View {
        let cam = model.activeCamera
        let roll = model.activeRoll(for: cam.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.cameras) { c in
                        Button {
                            model.selectCamera(c.id)
                        } label: {
                            if c.id == cam.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                        }
                    }
                } label: {
                    Chip(icon: "camera", text: cam.name, highlighted: true)
                }
                Button { model.sheet = .lens } label: {
                    Chip(icon: "circle.circle", text: cam.selectedLens.map { "\(Int($0.focalLength))mm" } ?? "Lens")
                }
                Button { model.sheet = .rolls } label: {
                    if let r = roll {
                        Chip(icon: "film", text: "\(shortStock(r.stock?.name)) · \(r.frames.count)/\(r.capacity)")
                    } else {
                        Chip(icon: "film", text: "No roll · \(shortStock(model.stock(for: cam)?.name ?? "No stock"))")
                    }
                }
                Spacer(minLength: 0)
                Button { model.sheet = .settings } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).padding(8)
                }
            }
            if let o = model.other {
                Text("\(o.cameraName) (\(shortStock(o.stockName))): f/\(ExposureMath.formatAperture(o.reading.aperture)) at \(ExposureMath.formatShutter(o.reading.shutter))")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, compact ? 8 : 4)
        .padding(.bottom, 6)
    }

    private func shortStock(_ name: String?) -> String {
        guard let name else { return "—" }
        return name.replacingOccurrences(of: "Kodak ", with: "").replacingOccurrences(of: "Ilford ", with: "")
            .replacingOccurrences(of: "Fujifilm ", with: "")
    }
}

struct LensPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.activeCamera.lenses) { lens in
                    Button {
                        model.selectLens(lens.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(lens.name)
                                Text(lens.label).font(.caption).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            if lens.id == model.activeCamera.selectedLens?.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .navigationTitle(model.activeCamera.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { Button("Edit gear") { model.sheet = .gear } }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack {
            Spacer()
            if let t = model.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if model.toast == t { model.toast = nil }
                    }
            }
        }
        .padding(.bottom, 180)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}

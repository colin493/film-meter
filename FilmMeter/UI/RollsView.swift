import SwiftUI

struct RollsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loadFor: CameraBody?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.cameras) { cam in
                    Section {
                        if let roll = model.activeRoll(for: cam.id) {
                            NavigationLink { RollDetailView(rollID: roll.id) } label: { RollRow(roll: roll, active: true) }
                            Button(role: .destructive) { model.finishRoll(roll.id) } label: { Label("Finish roll", systemImage: "checkmark.circle") }
                        } else {
                            Picker(selection: previewBinding(cam)) {
                                Text("No film simulation").tag("none")
                                ForEach(FilmKind.allCases) { kind in
                                    Section(kind.rawValue) {
                                        ForEach(StockLibrary.all.filter { $0.kind == kind }) { s in Text(s.name).tag(s.id) }
                                    }
                                }
                            } label: {
                                Label("Preview", systemImage: "eye")
                            }
                            .pickerStyle(.navigationLink)
                        }
                        Button { loadFor = cam } label: { Label("Load a new roll", systemImage: "plus.circle") }
                    } header: {
                        Text(cam.name)
                    } footer: {
                        if model.activeRoll(for: cam.id) == nil {
                            Text("With no roll loaded, the app previews this stock. \"No film simulation\" meters at the ISO set in Settings.")
                        }
                    }
                }
                let past = model.rolls.filter { !$0.isActive }.reversed()
                if !past.isEmpty {
                    Section {
                        ForEach(Array(past)) { roll in
                            NavigationLink { RollDetailView(rollID: roll.id) } label: { RollRow(roll: roll, active: false) }
                                .swipeActions { Button(role: .destructive) { model.deleteRoll(roll.id) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    } header: {
                        Text("Finished rolls")
                    } footer: {
                        Text("Swipe left on a roll to delete it.")
                    }
                }
                Section("Saved compositions") {
                    if model.compositions.isEmpty {
                        Text("Lock a frame, then save it to revisit exposure and aperture later.").font(.footnote).foregroundStyle(Theme.dim)
                    }
                    ForEach(model.compositions) { c in
                        Button { model.openComposition(c) } label: { CompositionRow(meta: c) }
                            .swipeActions { Button(role: .destructive) { model.deleteComposition(c) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            .navigationTitle("Rolls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $loadFor) { cam in
                LoadRollView(cameraID: cam.id).environmentObject(model).preferredColorScheme(.dark)
            }
        }
    }

    /// The stock a camera previews when it has no roll loaded ("none" = no film simulation).
    private func previewBinding(_ cam: CameraBody) -> Binding<String> {
        Binding(
            get: {
                let id = model.cameras.first { $0.id == cam.id }?.previewStockID ?? "none"
                return StockLibrary.stock(id) == nil ? "none" : id
            },
            set: { v in
                if let i = model.cameras.firstIndex(where: { $0.id == cam.id }) { model.cameras[i].previewStockID = v }
                model.refresh()
            }
        )
    }
}

struct RollRow: View {
    let roll: Roll
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(roll.stock?.name ?? roll.stockID).font(.body.weight(.medium))
                if roll.pushStops != 0 { Text(roll.pushLabel).font(.caption).foregroundStyle(Theme.accent) }
            }
            Text("\(roll.frames.count) of \(roll.capacity) frames · EI \(Int(roll.effectiveISO.rounded())) · loaded \(roll.loadedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(Theme.dim)
        }
    }
}

struct CompositionRow: View {
    let meta: CompositionMeta

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: Store.thumbnailURL(meta.id)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Theme.chip
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(StockLibrary.stock(meta.stockID)?.name ?? "No stock").font(.subheadline)
                Text("\(meta.cameraName) · f/\(ExposureMath.formatAperture(meta.aperture)) · \(ExposureMath.formatShutter(meta.shutter))")
                    .font(.caption).foregroundStyle(Theme.dim)
                Text(meta.date.formatted(date: .abbreviated, time: .shortened) + (meta.frameNumber.map { " · frame \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct RollDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    let rollID: UUID

    var body: some View {
        if let roll = model.rolls.first(where: { $0.id == rollID }) {
            List {
                Section {
                    LabeledContent("Stock", value: roll.stock?.name ?? roll.stockID)
                    LabeledContent("Rated", value: "EI \(Int(roll.effectiveISO.rounded())) (\(roll.pushLabel))")
                    LabeledContent("Camera", value: model.cameras.first { $0.id == roll.cameraID }?.name ?? "—")
                    if roll.pushStops != 0 {
                        Text("Tell the lab: \(roll.pushLabel).").font(.footnote).foregroundStyle(Theme.accent)
                    }
                }
                Section("Frames") {
                    if roll.frames.isEmpty { Text("No frames logged yet.").foregroundStyle(Theme.dim) }
                    ForEach(roll.frames.sorted { $0.number < $1.number }) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(f.number)").font(.body.monospacedDigit().weight(.semibold))
                                Text("f/\(ExposureMath.formatAperture(f.aperture)) · \(ExposureMath.formatShutter(f.shutter))")
                                Spacer()
                                Text(f.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.dim)
                            }
                            Text("\(f.lensName) · \(f.mode) · \(f.metering) · \(ExposureMath.formatEV(f.sceneEV100))")
                                .font(.caption).foregroundStyle(Theme.dim)
                            if !f.filters.isEmpty { Text(f.filters.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.dim) }
                            if let n = f.reciprocityNote { Text(n).font(.caption2).foregroundStyle(Theme.accent) }
                            if let cid = f.compositionID, let meta = model.compositions.first(where: { $0.id == cid }) {
                                Button("Open saved composition") { model.openComposition(meta) }.font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle(roll.stock?.name ?? "Roll")
            .toolbar {
                if !roll.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    }
                }
            }
            .confirmationDialog("Delete this roll and its frame log?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete roll", role: .destructive) {
                    model.deleteRoll(roll.id)
                    dismiss()
                }
            }
        } else {
            Text("Roll deleted").foregroundStyle(Theme.dim)
        }
    }
}

struct LoadRollView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let cameraID: UUID
    @State private var stockID = "portra400"
    @State private var push = 0.0
    @State private var capacity = 36
    /// The stock list opens as a pushed screen, and coming back from it fires onAppear again.
    /// Only fill in the defaults the first time, or the pick snaps back.
    @State private var didSetDefaults = false

    var body: some View {
        let cam = model.cameras.first { $0.id == cameraID } ?? model.activeCamera
        NavigationStack {
            Form {
                Section("Camera") { Text(cam.name) }
                Section("Stock") {
                    Picker("Stock", selection: $stockID) {
                        ForEach(FilmKind.allCases) { kind in
                            Section(kind.rawValue) {
                                ForEach(StockLibrary.all.filter { $0.kind == kind }) { s in Text(s.name).tag(s.id) }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if let s = StockLibrary.stock(stockID) {
                        Text("\(s.dataSheet). \(s.sheetNote)").font(.caption).foregroundStyle(Theme.dim)
                    }
                }
                Section {
                    Stepper(value: $push, in: -2...3, step: 1.0 / 3.0) {
                        let iso = (StockLibrary.stock(stockID)?.iso ?? 100) * pow(2, push)
                        Text(push == 0 ? "Box speed" : "\(push > 0 ? "Push" : "Pull") \(ExposureMath.formatStops(abs(push), signed: false)) · EI \(Int(iso.rounded()))")
                    }
                    Stepper("Frames: \(capacity)", value: $capacity, in: 1...80)
                } footer: {
                    Text("Push and pull apply to the whole roll, since the lab develops it in one go.")
                }
                Section {
                    Button("Load roll") {
                        model.loadRoll(camera: cam, stockID: stockID, push: push, capacity: capacity)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Load roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                guard !didSetDefaults else { return }
                didSetDefaults = true
                capacity = cam.format.defaultFrames
                if let s = model.activeRoll(for: cam.id)?.stockID ?? StockLibrary.stock(cam.previewStockID)?.id { stockID = s }
            }
        }
    }
}

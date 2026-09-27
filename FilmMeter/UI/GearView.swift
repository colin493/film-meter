import SwiftUI

struct GearView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Cameras") {
                    ForEach($model.cameras) { $cam in
                        NavigationLink { CameraEditor(camera: $cam) } label: {
                            VStack(alignment: .leading) {
                                Text(cam.name)
                                Text("\(cam.format.rawValue) · \(cam.lenses.map { "\(Int($0.focalLength))mm" }.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                    .onDelete { idx in
                        guard model.cameras.count - idx.count >= 1 else { return }
                        model.cameras.remove(atOffsets: idx)
                        model.refresh()
                    }
                    Button {
                        let lens = Lens(name: "50mm", focalLength: 50, maxAperture: 2, minAperture: 16)
                        model.cameras.append(CameraBody(name: "New camera", format: .f135, fastestShutter: 1.0 / 1000, slowestShutter: 1,
                                                        lenses: [lens], selectedLensID: lens.id))
                    } label: { Label("Add a camera", systemImage: "plus") }
                }
                Section("Filters") {
                    ForEach($model.filters) { $f in
                        NavigationLink { FilterEditor(filter: $f) } label: {
                            HStack {
                                Text(f.name)
                                Spacer()
                                Text(ExposureMath.formatStops(f.factorStops)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                    .onDelete { model.filters.remove(atOffsets: $0) }
                    Button {
                        model.filters.append(FilterDef(name: "New filter", factorStops: 1))
                    } label: { Label("Add a filter", systemImage: "plus") }
                }
            }
            .navigationTitle("Cameras, lenses & filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.updateZoom(); dismiss() } } }
        }
    }
}

struct CameraEditor: View {
    @Binding var camera: CameraBody
    private let speeds = ExposureMath.fullShutters + [1.0 / 6000]

    var body: some View {
        Form {
            Section("Body") {
                TextField("Name", text: $camera.name)
                Picker("Format", selection: $camera.format) {
                    ForEach(FilmFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Fastest shutter", selection: $camera.fastestShutter) {
                    ForEach(speeds.filter { $0 <= 1.0 / 60 }.sorted(), id: \.self) { Text(ExposureMath.formatShutter($0)).tag($0) }
                }
                Picker("Slowest timed shutter", selection: $camera.slowestShutter) {
                    ForEach(ExposureMath.fullShutters.filter { $0 >= 1.0 / 30 }, id: \.self) { Text(ExposureMath.formatShutter($0)).tag($0) }
                }
                Picker("Shutter steps", selection: $camera.shutterStep) {
                    Text("Full stops").tag(StopStep.full)
                    Text("Third stops").tag(StopStep.third)
                }
                Toggle("Bulb", isOn: $camera.hasBulb)
            }
            Section("Lenses") {
                ForEach($camera.lenses) { $lens in
                    NavigationLink { LensEditor(lens: $lens) } label: { Text("\(lens.name) · \(lens.label)") }
                }
                .onDelete { idx in if camera.lenses.count - idx.count >= 1 { camera.lenses.remove(atOffsets: idx) } }
                Button {
                    camera.lenses.append(Lens(name: "New lens", focalLength: 50, maxAperture: 2.8, minAperture: 16))
                } label: { Label("Add a lens", systemImage: "plus") }
            }
        }
        .navigationTitle(camera.name)
    }
}

struct LensEditor: View {
    @Binding var lens: Lens

    var body: some View {
        Form {
            TextField("Name", text: $lens.name)
            Stepper("Focal length: \(Int(lens.focalLength))mm", value: $lens.focalLength, in: 8...600, step: 1)
            Picker("Widest aperture", selection: $lens.maxAperture) {
                ForEach(ExposureMath.thirdApertures.filter { $0 <= 8 }, id: \.self) { Text("f/" + ExposureMath.formatAperture($0)).tag($0) }
                ForEach([3.5, 4.5, 6.3].filter { !ExposureMath.thirdApertures.contains($0) }, id: \.self) { Text("f/" + ExposureMath.formatAperture($0)).tag($0) }
            }
            Picker("Smallest aperture", selection: $lens.minAperture) {
                ForEach([11.0, 16, 22, 32, 45, 64], id: \.self) { Text("f/" + ExposureMath.formatAperture($0)).tag($0) }
            }
            Picker("Aperture clicks", selection: $lens.apertureStep) {
                ForEach(StopStep.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        .navigationTitle(lens.name)
    }
}

struct FilterEditor: View {
    @Binding var filter: FilterDef

    var body: some View {
        Form {
            TextField("Name", text: $filter.name)
            Stepper("Filter factor: \(ExposureMath.formatStops(filter.factorStops)) stops", value: $filter.factorStops, in: 0...13, step: 1.0 / 3.0)
            Toggle("Polarizer", isOn: $filter.isPolarizer)
            if filter.isPolarizer {
                Text("Mark the ring once: look at glare on a table through the filter, turn it until the glare fades most, and dot the ring at 12 o'clock. Mount it with the dot at the top. The preview assumes that position.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            Section("Colour (for B&W contrast and warming)") {
                ForEach(0..<3, id: \.self) { i in
                    HStack {
                        Text(["Red", "Green", "Blue"][i])
                        Slider(value: Binding(get: { filter.transmission.count == 3 ? filter.transmission[i] : 1 },
                                              set: { v in
                                                  if filter.transmission.count != 3 { filter.transmission = [1, 1, 1] }
                                                  filter.transmission[i] = v
                                              }), in: 0...1)
                        Text(String(format: "%.2f", filter.transmission.count == 3 ? filter.transmission[i] : 1)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(filter.name)
    }
}

struct FiltersSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cam = model.activeCamera
        let active = model.activeFilters(for: cam)
        NavigationStack {
            List {
                Section {
                    ForEach(model.filters) { f in
                        Button {
                            model.toggleFilter(f)
                        } label: {
                            HStack {
                                Image(systemName: active.contains(f) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(active.contains(f) ? Theme.accent : Theme.dim)
                                Text(f.name).foregroundStyle(.white)
                                Spacer()
                                Text(ExposureMath.formatStops(f.factorStops)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                } footer: {
                    let total = active.reduce(0) { $0 + $1.factorStops }
                    Text(active.isEmpty ? "Stacked filters add their factors; the meter compensates automatically."
                         : "On the \(cam.name): \(ExposureMath.formatStops(total)) stops of compensation, already in the reading.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { Button("Edit") { model.sheet = .gear } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $model.settings.calibrationThirds, in: -9...9) {
                        Text("Meter offset: \(ExposureMath.formatStops(Double(model.settings.calibrationThirds) / 3)) stops")
                    }
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("Point this app and a meter you trust (the G2's works) at the same evenly lit wall. If they differ, dial the difference in here once.")
                }

                Section {
                    Toggle("Your look (fitted to your scans)", isOn: $model.settings.houseLook)
                    Toggle("Grain", isOn: $model.settings.showGrain)
                    Toggle("Clipping stripes on locked frames", isOn: $model.settings.zebras)
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Your look renders greens away from yellow, as you asked.")
                }

                Section("Without film simulation") {
                    Picker("ISO when no stock is set", selection: $model.settings.neutralISO) {
                        ForEach([50.0, 100, 125, 160, 200, 400, 800, 1600, 3200], id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                }

                Section("Units") {
                    Picker("Distances", selection: $model.settings.useFeet) {
                        Text("Feet").tag(true)
                        Text("Metres").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Gear") {
                    Button("Cameras, lenses and filters") { model.sheet = .gear }
                }

                Section {
                    Text(model.camera.formatSummary.isEmpty ? "Camera not started" : model.camera.formatSummary)
                        .font(.caption).foregroundStyle(Theme.dim)
                    if !model.zoomStatus.isEmpty {
                        Text(model.zoomStatus).font(.caption).foregroundStyle(Theme.dim)
                    }
                } header: {
                    Text("Camera details")
                } footer: {
                    Text("Send Claude a screenshot of this if the framing or depth looks wrong.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

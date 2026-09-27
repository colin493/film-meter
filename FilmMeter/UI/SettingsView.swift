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
                    VStack(alignment: .leading) {
                        Text("Greens: \(model.settings.greensShift == 0 ? "as tuned" : String(format: "%+.0f°", model.settings.greensShift))")
                        Slider(value: $model.settings.greensShift, in: -15...15, step: 1) {
                            Text("Greens")
                        } minimumValueLabel: { Text("Yellower").font(.caption2) } maximumValueLabel: { Text("Cooler").font(.caption2) }
                    }
                    Toggle("Grain", isOn: $model.settings.showGrain)
                    Toggle("Clipping stripes on locked frames", isOn: $model.settings.zebras)
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Greens are already shifted away from yellow; this slider fine-tunes from there.")
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

                Section("Stock data") {
                    ForEach(StockLibrary.all) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline)
                            Text("ISO \(Int(s.iso)) · \(s.dataSheet)").font(.caption).foregroundStyle(Theme.dim)
                            Text(s.reciprocity.note).font(.caption2).foregroundStyle(Theme.dim)
                            Text("Detail from \(ExposureMath.formatStops(s.shadowLimit)) to \(ExposureMath.formatStops(s.highlightLimit)) stops around middle grey (approximate).")
                                .font(.caption2).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

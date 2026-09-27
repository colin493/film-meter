import Foundation

enum FilmFormat: String, Codable, CaseIterable, Identifiable {
    case f135 = "35mm"
    case halfFrame = "Half frame"
    case f645 = "6×4.5"
    case f66 = "6×6"
    case f67 = "6×7"

    var id: String { rawValue }

    /// Frame size in mm, long side first.
    var size: (long: Double, short: Double) {
        switch self {
        case .f135: return (36, 24)
        case .halfFrame: return (24, 18)
        case .f645: return (56, 41.5)
        case .f66: return (56, 56)
        case .f67: return (69.5, 56)
        }
    }

    var isSquare: Bool { self == .f66 }
    var aspect: Double { size.long / size.short }
    var diagonal: Double { (size.long * size.long + size.short * size.short).squareRoot() }
    /// Circle of confusion for depth-of-field sums (diagonal / 1500).
    var circleOfConfusion: Double { diagonal / 1500 }
    var defaultFrames: Int {
        switch self {
        case .f135: return 36
        case .halfFrame: return 72
        case .f645: return 15
        case .f66: return 12
        case .f67: return 10
        }
    }
    /// Grain amplitude relative to 35mm at the same viewing size.
    var grainScale: Double { (864.0 / (size.long * size.short)).squareRoot() }
}

enum StopStep: String, Codable, CaseIterable, Identifiable {
    case full = "Full", half = "Half", third = "Third"
    var id: String { rawValue }
}

struct Lens: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var focalLength: Double
    var maxAperture: Double
    var minAperture: Double
    var apertureStep: StopStep = .half

    var apertureStops: [Double] {
        let series: [Double]
        switch apertureStep {
        case .full: series = ExposureMath.fullApertures
        case .half: series = ExposureMath.halfApertures
        case .third: series = ExposureMath.thirdApertures
        }
        var out = [maxAperture]
        for f in series where f > maxAperture * 1.03 && f <= minAperture * 1.01 { out.append(f) }
        return out
    }

    var label: String { "\(Int(focalLength.rounded()))mm f/\(ExposureMath.formatAperture(maxAperture))" }
}

struct CameraBody: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var format: FilmFormat
    var fastestShutter: Double
    var slowestShutter: Double
    var shutterStep: StopStep = .full
    var hasBulb: Bool = true
    var lenses: [Lens]
    var selectedLensID: UUID?
    /// Stock previewed when no roll is loaded in this body.
    var previewStockID: String = "portra400"

    var selectedLens: Lens? {
        lenses.first { $0.id == selectedLensID } ?? lenses.first
    }

    var shutterSpeeds: [Double] {
        let series = shutterStep == .third ? ExposureMath.thirdShutters : ExposureMath.fullShutters
        var out = series.filter { $0 >= fastestShutter * 0.97 && $0 <= slowestShutter * 1.03 }
        if !out.contains(where: { abs(log2($0 / fastestShutter)) < 0.1 }) { out.insert(fastestShutter, at: 0) }
        return out.sorted()
    }
}

struct FilterDef: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var factorStops: Double
    /// Relative transmission of linear R, G, B.
    var transmission: [Double] = [1, 1, 1]
    var isPolarizer: Bool = false
}

enum GearDefaults {
    static func cameras() -> [CameraBody] {
        let g28 = Lens(name: "Biogon 28mm", focalLength: 28, maxAperture: 2.8, minAperture: 22)
        let g45 = Lens(name: "Planar 45mm", focalLength: 45, maxAperture: 2, minAperture: 16)
        let g90 = Lens(name: "Sonnar 90mm", focalLength: 90, maxAperture: 2.8, minAperture: 22)
        let m50 = Lens(name: "G 50mm", focalLength: 50, maxAperture: 4, minAperture: 22)
        let m75 = Lens(name: "G 75mm", focalLength: 75, maxAperture: 3.5, minAperture: 22)
        let m150 = Lens(name: "G 150mm", focalLength: 150, maxAperture: 4.5, minAperture: 32)
        return [
            CameraBody(name: "Contax G2", format: .f135, fastestShutter: 1.0 / 6000, slowestShutter: 16,
                       lenses: [g28, g45, g90], selectedLensID: g45.id, previewStockID: "portra400"),
            CameraBody(name: "Mamiya 6", format: .f66, fastestShutter: 1.0 / 500, slowestShutter: 4,
                       lenses: [m50, m75, m150], selectedLensID: m75.id, previewStockID: "portra400"),
        ]
    }

    static func filters() -> [FilterDef] {
        [
            FilterDef(name: "Circular polarizer", factorStops: 1.5, isPolarizer: true),
            FilterDef(name: "UV / Skylight", factorStops: 0, transmission: [1, 1, 0.97]),
            FilterDef(name: "81A warming", factorStops: 1.0 / 3.0, transmission: [1, 0.93, 0.80]),
            FilterDef(name: "85B (tungsten film in daylight)", factorStops: 2.0 / 3.0, transmission: [1, 0.78, 0.45]),
            FilterDef(name: "80A (daylight film in tungsten)", factorStops: 2, transmission: [0.45, 0.72, 1]),
            FilterDef(name: "Yellow 8", factorStops: 1, transmission: [1, 0.95, 0.25]),
            FilterDef(name: "Orange 21", factorStops: 2, transmission: [1, 0.55, 0.05]),
            FilterDef(name: "Red 25A", factorStops: 3, transmission: [1, 0.08, 0.02]),
            FilterDef(name: "Green 11", factorStops: 2, transmission: [0.35, 1, 0.35]),
            FilterDef(name: "ND 0.3 (1 stop)", factorStops: 1),
            FilterDef(name: "ND 0.6 (2 stops)", factorStops: 2),
            FilterDef(name: "ND 0.9 (3 stops)", factorStops: 3),
            FilterDef(name: "ND 1.8 (6 stops)", factorStops: 6),
            FilterDef(name: "ND 3.0 (10 stops)", factorStops: 10),
        ]
    }
}

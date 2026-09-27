import Foundation

struct FrameLog: Codable, Identifiable, Hashable {
    var id = UUID()
    var number: Int
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var lensName: String
    var aperture: Double
    var shutter: Double
    var reciprocityNote: String?
    var sceneEV100: Double
    var mode: String
    var metering: String
    var filters: [String]
    var compositionID: UUID?
    var note: String = ""
}

struct Roll: Codable, Identifiable, Hashable {
    var id = UUID()
    var cameraID: UUID
    var stockID: String
    var pushStops: Double
    var capacity: Int
    var loadedAt: Date
    var finishedAt: Date?
    var frames: [FrameLog] = []

    var isActive: Bool { finishedAt == nil }
    var nextFrame: Int { (frames.map(\.number).max() ?? 0) + 1 }
    var stock: FilmStock? { StockLibrary.stock(stockID) }
    var effectiveISO: Double { (stock?.iso ?? 100) * pow(2, pushStops) }
    var pushLabel: String {
        if pushStops == 0 { return "box speed" }
        return (pushStops > 0 ? "push " : "pull ") + ExposureMath.formatStops(abs(pushStops), signed: false)
    }
}

/// A locked frame saved for later: everything needed to re-render it at other settings.
struct CompositionMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var cameraID: UUID
    var cameraName: String
    var lensName: String
    var focalLength: Double
    var format: FilmFormat
    var stockID: String?
    var pushStops: Double
    var filterNames: [String]
    var filterIDs: [UUID]
    /// Scene EV100 the film's middle grey was placed at (after compensation and setting residual).
    var placementEV: Double
    /// Meter reading before compensation, and the compensation in force at lock.
    var meterEV: Double
    var compensation: Double
    var filmISO: Double
    var baseEV100: Double          // phone exposure of the base frame, calibration included
    var aperture: Double
    var shutter: Double
    var focusM: Double?
    var display: DisplayOrientation
    var width: Int
    var height: Int
    var depthWidth: Int
    var depthHeight: Int
    var latitude: Double?
    var longitude: Double?
    var sun: SunPosition?
    var sky: SkyGrid?
    var rollID: UUID?
    var frameNumber: Int?
}

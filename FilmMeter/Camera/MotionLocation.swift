import CoreLocation
import CoreMotion
import Foundation
import simd

/// Device attitude (for the polarizer and backlight detection) and location (for the sun).
final class MotionLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var _attitude: Attitude?
    private var _coordinate: CLLocationCoordinate2D?

    @Published private(set) var hasLocation = false
    @Published private(set) var hasHeading = false

    var attitude: Attitude? { lock.lock(); defer { lock.unlock() }; return _attitude }
    var coordinate: CLLocationCoordinate2D? { lock.lock(); defer { lock.unlock() }; return _coordinate }

    func sun(at date: Date = Date()) -> SunPosition? {
        guard let c = coordinate else { return nil }
        return SunPosition.compute(date: date, latitude: c.latitude, longitude: c.longitude)
    }

    func start() {
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()

        guard motion.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let ref: CMAttitudeReferenceFrame
        if frames.contains(.xTrueNorthZVertical) { ref = .xTrueNorthZVertical }
        else if frames.contains(.xMagneticNorthZVertical) { ref = .xMagneticNorthZVertical }
        else { ref = .xArbitraryCorrectedZVertical }
        let northReferenced = ref != .xArbitraryCorrectedZVertical
        queue.maxConcurrentOperationCount = 1
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(using: ref, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            self.update(m, northReferenced: northReferenced)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
    }

    private func update(_ m: CMDeviceMotion, northReferenced: Bool) {
        let r = m.attitude.rotationMatrix
        let rm = [r.m11, r.m12, r.m13, r.m21, r.m22, r.m23, r.m31, r.m32, r.m33]
        // Work out which way the matrix maps by checking that world "down" lands on measured gravity.
        let g = SIMD3<Double>(m.gravity.x, m.gravity.y, m.gravity.z)
        let colDown = -SIMD3<Double>(r.m13, r.m23, r.m33)   // if device = R · world
        let rowDown = -SIMD3<Double>(r.m31, r.m32, r.m33)   // if world = R · device
        let useRowConvention = simd_length(g - rowDown) <= simd_length(g - colDown)
        let deviceToWorld = useRowConvention ? rm : [rm[0], rm[3], rm[6], rm[1], rm[4], rm[7], rm[2], rm[5], rm[8]]
        let att = Attitude(m: deviceToWorld, hasTrueNorth: northReferenced)
        lock.lock(); _attitude = att; lock.unlock()
        if northReferenced != hasHeading { DispatchQueue.main.async { self.hasHeading = northReferenced } }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        lock.lock(); _coordinate = c; lock.unlock()
        if !hasLocation { DispatchQueue.main.async { self.hasLocation = true } }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

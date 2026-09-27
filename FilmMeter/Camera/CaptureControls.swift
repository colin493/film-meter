import AVFoundation

/// Puts exposure compensation and aperture on the iPhone's Camera Control button.
final class CaptureControls: NSObject, AVCaptureSessionControlsDelegate {
    private let queue = DispatchQueue(label: "film.capturecontrols")
    var onCompensation: ((Double) -> Void)?
    var onApertureIndex: ((Int) -> Void)?

    func install(on session: AVCaptureSession, compensation: Double, apertureTitles: [String], apertureIndex: Int) {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.setControlsDelegate(self, queue: queue)
        session.controls.forEach { session.removeControl($0) }

        let comp = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: -3...3, step: 1.0 / 3.0)
        comp.value = Float(compensation)
        comp.setActionQueue(queue) { [weak self] v in
            let snapped = (Double(v) * 3).rounded() / 3
            DispatchQueue.main.async { self?.onCompensation?(snapped) }
        }
        var controls: [AVCaptureControl] = [comp]
        if !apertureTitles.isEmpty {
            let picker = AVCaptureIndexPicker("Aperture", symbolName: "camera.aperture", localizedIndexTitles: apertureTitles)
            picker.selectedIndex = max(0, min(apertureTitles.count - 1, apertureIndex))
            picker.setActionQueue(queue) { [weak self] i in
                DispatchQueue.main.async { self?.onApertureIndex?(i) }
            }
            controls.append(picker)
        }
        for c in controls where session.canAddControl(c) { session.addControl(c) }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

import MetalKit
import SwiftUI

struct MetalPreview: UIViewRepresentable {
    let renderer: LiveRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero)
        renderer.configure(v)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

struct ViewfinderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fit(aspect: model.cropAspect, in: geo.size)
            ZStack(alignment: .topLeading) {
                MetalPreview(renderer: model.processor.renderer)
                if !model.camera.isAuthorized {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text("Camera access is off. Turn it on in Settings to meter.").multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.dim)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                if model.settings.metering == .subject, let p = model.subjectPoint {
                    Circle()
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                        .overlay(Circle().fill(Theme.accent).frame(width: 4, height: 4))
                        .position(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                }
                if model.settings.metering == .matrix, let s = model.stats {
                    ForEach(Array(s.faces.enumerated()), id: \.offset) { _, f in
                        let r = framed(f, rect: rect)
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let note = model.zoomNote { Badge(text: note) }
                    if model.camera.isRunning && !model.camera.hasDepth { Badge(text: "No depth on this phone: depth of field preview is off") }
                    if model.activeFilters(for: model.activeCamera).contains(where: { $0.isPolarizer }) && !model.motion.hasHeading {
                        Badge(text: "Polarizer needs location and compass")
                    }
                }
                .padding(.leading, rect.minX + 8)
                .padding(.top, rect.minY + 8)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { v in
                    let p = v.location
                    guard rect.contains(p) else { return }
                    model.tapSubject(CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
                }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.lock() }
            )
        }
    }

    /// Face boxes arrive in full-frame upright coordinates; map them into the framed view.
    private func framed(_ f: CGRect, rect: CGRect) -> CGRect {
        let crop = model.uprightCrop
        let x = (f.minX - crop.minX) / crop.width, y = (f.minY - crop.minY) / crop.height
        return CGRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                      width: f.width / crop.width * rect.width, height: f.height / crop.height * rect.height)
    }

    static func fit(aspect: Double, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let a = CGFloat(aspect)
        var w = size.width, h = size.width / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white.opacity(0.9))
    }
}

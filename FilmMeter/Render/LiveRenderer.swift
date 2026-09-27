import CoreImage
import Metal
import MetalKit
import UIKit

/// Draws the latest processed CIImage into an MTKView, aspect-fit.
final class LiveRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    let context: CIContext
    private let lock = NSLock()
    private var image: CIImage?
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                        .cacheIntermediates: false])
        super.init()
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = view.layer as? CAMetalLayer { layer.colorspace = p3 }
    }

    func setImage(_ img: CIImage) {
        lock.lock(); image = img; lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let img = image; lock.unlock()
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        var out = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        if let img, img.extent.width > 0, img.extent.height > 0 {
            let s = min(size.width / img.extent.width, size.height / img.extent.height)
            let w = img.extent.width * s, h = img.extent.height * s
            let placed = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
            out = placed.composited(over: out)
        }
        context.render(out, to: drawable.texture, commandBuffer: cb, bounds: CGRect(origin: .zero, size: size), colorSpace: p3)
        cb.present(drawable)
        cb.commit()
    }
}

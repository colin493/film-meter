import CoreImage

enum Grain {
    private static let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!

    /// Adds monochrome, zero-mean grain. `amount` is the grain's standard deviation in display units.
    static func apply(to image: CIImage, amount: Float, seed: Int) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, !ext.isInfinite else { return image }
        let a = CGFloat(amount) * 3.4   // uniform noise has sd ≈ 0.29
        let dx = CGFloat((seed &* 7919) % 997), dy = CGFloat((seed &* 104729) % 991)
        let grain = noise
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -a / 2, y: -a / 2, z: -a / 2, w: 0),
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
            .cropped(to: ext)
        return grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: ext)
    }

    /// Grain strength for a stock on a format, including push and underexposure.
    static func amount(stock: FilmStock?, format: FilmFormat, pushStops: Double, underexposure: Double) -> Float {
        guard let s = stock else { return 0 }
        var g = s.grain * format.grainScale * pow(1.25, max(0, pushStops))
        if s.kind != .slide { g *= pow(1.2, max(0, underexposure)) }
        return Float(0.018 * g)
    }
}

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Isolates the real camera hands before tinting them. Capture, mask and image
/// share one timestamp; no old mask can reveal unrelated pixels after movement.
final class CameraGhostRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let filter = CIFilter.colorMatrix()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let segmenter = LiveHandMask()

    init() {
        // Retain live photographic shading, with a blue/cyan hologram tint.
        func channel(_ tint: CGFloat) -> CIVector {
            CIVector(x: 0.2126 * tint, y: 0.7152 * tint, z: 0.0722 * tint, w: 0)
        }
        filter.rVector = channel(0.10)
        filter.gVector = channel(0.58)
        filter.bVector = channel(0.95)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0.005, y: 0.025, z: 0.05, w: 0)
    }

    func render(_ buffer: CVPixelBuffer, poses: [HandMaskPose]) -> CGImage? {
        guard let mask = segmenter.makeMask(buffer: buffer, poses: poses) else { return nil }
        return composite(buffer, mask: mask)
    }

    /// Separate composition also permits calibration tests with known mattes.
    func composite(_ buffer: CVPixelBuffer, mask: CGImage) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        filter.inputImage = source
        defer { filter.inputImage = nil }
        guard let tinted = filter.outputImage else { return nil }
        let matte = CIImage(cgImage: mask).transformed(by: CGAffineTransform(
            scaleX: source.extent.width / CGFloat(mask.width), y: source.extent.height / CGFloat(mask.height)))
        let clear = CIImage(color: .clear).cropped(to: source.extent)
        func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
            image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        }
        let body = masked(tinted, by: matte.applyingGaussianBlur(sigma: 0.8).cropped(to: source.extent))
        let glowColor = CIImage(color: CIColor(red: 0.04, green: 0.38, blue: 0.72, alpha: 0.25)).cropped(to: source.extent)
        let glow = masked(glowColor, by: matte.applyingGaussianBlur(sigma: 3).cropped(to: source.extent))
        let result = body.composited(over: glow).cropped(to: source.extent)
        return context.createCGImage(result, from: source.extent, format: .RGBA8, colorSpace: colorSpace)
    }
}

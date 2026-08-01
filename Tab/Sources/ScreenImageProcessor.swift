import AppKit
import CoreGraphics
import Vision

enum ScreenImageProcessor {
    static func grayscaleSamples(
        from image: CGImage,
        width: Int = 32,
        height: Int = 18
    ) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        var samples = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let drewImage = samples.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drewImage ? samples : []
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.55) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: min(max(quality, 0), 1)]
        )
    }

    static func recognizedText(from image: CGImage, maximumCharacters: Int = 280) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).sorted { left, right in
            let verticalDistance = abs(left.boundingBox.midY - right.boundingBox.midY)
            if verticalDistance > 0.025 {
                return left.boundingBox.midY > right.boundingBox.midY
            }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        let rawText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " · ")
        let collapsed = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maximumCharacters))
    }
}

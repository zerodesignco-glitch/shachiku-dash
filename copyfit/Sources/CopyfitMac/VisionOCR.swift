#if canImport(Vision) && canImport(ImageIO)
import CopyfitCore
import Foundation
import ImageIO
import Vision

/// OS標準Visionによるローカル OCR。ネットワークは使わない。
public struct VisionOCR: OCRProvider {
    public init() {}

    public var engineDescription: String {
        "Apple Vision VNRecognizeTextRequest rev\(VNRecognizeTextRequest.currentRevision) (accurate, language correction off)"
    }

    public func supportedLanguages() -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try? request.supportedRecognitionLanguages()
    }

    public func recognize(imageURL: URL, facts: AssetFacts, languages: [String]) throws -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(facts.orientation)) ?? .up
        let handler = VNImageRequestHandler(url: imageURL, orientation: orientation, options: [:])
        try handler.perform([request])
        let revision = "Vision rev\(request.revision)"
        return (request.results ?? []).compactMap { obs -> OCRObservation? in
            guard let top = obs.topCandidates(1).first else { return nil }
            let bb = obs.boundingBox
            let rect = CoordinateConversion.visionNormalizedToPixel(
                x: Double(bb.origin.x), y: Double(bb.origin.y),
                width: Double(bb.size.width), height: Double(bb.size.height),
                imageWidth: facts.pixelWidth, imageHeight: facts.pixelHeight)
            return OCRObservation(text: top.string, boundingBox: rect, confidence: Double(top.confidence),
                                  language: languages.first, engineRevision: revision)
        }
    }
}
#endif

import Foundation
import Vision

/// On-device text recognition for image attachments (Zadanie 2.1). Uses the
/// Vision framework — free, offline, no account needed. The recognized text is
/// stored as hidden metadata in the note's `meta.json` (never inserted into the
/// note content) so that search can later match what's written inside images.
enum ImageOCR {
    /// Raster formats Vision can read (SVG is vector, so it's skipped).
    static let supportedExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]

    static func isSupportedImage(_ filename: String) -> Bool {
        supportedExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Recognizes text in the image file. Returns the recognized lines joined
    /// with newlines — an empty string when the image contains no text — or
    /// `nil` when the file couldn't be read or recognition failed.
    static func recognizeText(in url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Polish first (the app's primary language), English as fallback;
        // automatic detection handles anything else.
        request.recognitionLanguages = [Locale.Language(identifier: "pl-PL"),
                                        Locale.Language(identifier: "en-US")]
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: data) else { return nil }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

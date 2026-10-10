import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Turns a dropped or chosen reference file into plain text for a review profile.
public enum CriteriaImporter {
    public static let supportedExtensions = ["txt", "md", "markdown", "text", "docx", "rtf", "pdf"]
    /// Largest amount of text kept per file; longer files are refused rather than silently cut.
    public static let maxCharacters = 120_000

    public static func document(from url: URL) throws -> CriteriaDocument {
        let text = try extractText(from: url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ReviewError.unreadableDocument("“\(url.lastPathComponent)” doesn’t contain any text. Scanned PDFs and images can’t be read.")
        }
        guard text.count <= maxCharacters else {
            throw ReviewError.unsupportedDocument("“\(url.lastPathComponent)” is too long to use as criteria (limit \(maxCharacters / 1000),000 characters). Attach the relevant sections instead.")
        }
        return CriteriaDocument(name: url.deletingPathExtension().lastPathComponent, text: text)
    }

    static func extractText(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "text":
            var encoding = String.Encoding.utf8
            if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
            if let s = try? String(contentsOf: url, encoding: .windowsCP1252) { return s }
            throw ReviewError.unreadableDocument("“\(url.lastPathComponent)” isn’t a text file.")
        case "docx":
            return try RedlineEngine.readText(of: url).paragraphs.map(\.text).joined(separator: "\n")
        case "rtf":
            #if canImport(AppKit)
            if let a = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                               documentAttributes: nil) { return a.string }
            #endif
            throw ReviewError.unsupportedDocument("RTF files can’t be read here. Save “\(url.lastPathComponent)” as .docx, .pdf or .txt.")
        case "pdf":
            #if canImport(PDFKit)
            if let text = PDFDocument(url: url)?.string { return text }
            throw ReviewError.unreadableDocument("“\(url.lastPathComponent)” couldn’t be read as a PDF.")
            #else
            throw ReviewError.unsupportedDocument("PDF files can’t be read on this system.")
            #endif
        default:
            throw ReviewError.unsupportedDocument("“\(url.lastPathComponent)” isn’t a supported type. Use .docx, .pdf, .txt or .md.")
        }
    }
}

import Foundation

/// What Claude returns: suggested rewrites (become tracked changes) and remarks (become comments).
public struct ReviewPlan: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var paragraph: Int
        public var original: String
        public var revised: String
        public var comment: String?

        public init(paragraph: Int, original: String, revised: String, comment: String? = nil) {
            self.paragraph = paragraph
            self.original = original
            self.revised = revised
            self.comment = comment
        }
    }

    public struct Comment: Codable, Equatable, Sendable {
        public var paragraph: Int
        public var quote: String
        public var comment: String

        public init(paragraph: Int, quote: String, comment: String) {
            self.paragraph = paragraph
            self.quote = quote
            self.comment = comment
        }
    }

    public var summary: String
    public var edits: [Edit]
    public var comments: [Comment]

    public init(summary: String, edits: [Edit] = [], comments: [Comment] = []) {
        self.summary = summary
        self.edits = edits
        self.comments = comments
    }

    /// JSON Schema handed to `claude --json-schema` so the reply is validated before we see it.
    public static let jsonSchema: String = """
    {"type":"object","additionalProperties":false,"required":["summary","edits","comments"],"properties":{\
    "summary":{"type":"string"},\
    "edits":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["paragraph","original","revised"],"properties":{\
    "paragraph":{"type":"integer"},"original":{"type":"string"},"revised":{"type":"string"},"comment":{"type":"string"}}}},\
    "comments":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["paragraph","quote","comment"],"properties":{\
    "paragraph":{"type":"integer"},"quote":{"type":"string"},"comment":{"type":"string"}}}}}}
    """
}

/// One suggestion from the plan that could not be placed in the document, and why.
public struct SkippedItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case edit, comment }
    public let id = UUID()
    public let kind: Kind
    public let paragraph: Int
    public let excerpt: String
    public let reason: String

    public static func == (a: SkippedItem, b: SkippedItem) -> Bool {
        a.kind == b.kind && a.paragraph == b.paragraph && a.excerpt == b.excerpt && a.reason == b.reason
    }
}

public struct RedlineReport: Sendable {
    public var trackedChanges: Int
    public var comments: Int
    public var skipped: [SkippedItem]
}

public enum ReviewError: LocalizedError, Equatable {
    case unsupportedDocument(String)
    case unreadableDocument(String)
    case verificationFailed(String)
    case outputLocation(String)
    case claude(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedDocument(let m): return "This document can’t be reviewed: \(m)"
        case .unreadableDocument(let m): return "The document couldn’t be read: \(m)"
        case .verificationFailed(let m):
            // Anything after a blank line is diagnostic detail, shown only under "Technical details".
            return "The reviewed copy failed its integrity check, so it was not saved. \(m.components(separatedBy: "\n\n").first ?? m)"
        case .outputLocation(let m): return m
        case .claude(let m): return m
        case .cancelled: return "Review cancelled."
        }
    }
}

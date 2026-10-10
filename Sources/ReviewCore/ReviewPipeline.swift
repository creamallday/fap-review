import Foundation

public protocol PlanProvider: Sendable {
    func requestPlan(system: String, prompt: String) async throws -> ReviewPlan
}

extension ClaudeCLI: PlanProvider {}

public enum ReviewStage: Sendable, Equatable {
    case reading
    case reviewing
    case refining
    case writing
}

public struct ReviewRequest: Sendable {
    public var source: URL
    public var profile: ReviewProfile
    public var instructions: String
    public var author: String
    /// Where to save the reviewed copy. Nil means next to the original, or Documents if that folder is read-only.
    public var outputDirectory: URL?

    public init(source: URL, profile: ReviewProfile, instructions: String, author: String, outputDirectory: URL? = nil) {
        self.source = source
        self.profile = profile
        self.instructions = instructions
        self.author = author
        self.outputDirectory = outputDirectory
    }
}

public struct ReviewOutcome: Sendable {
    public let output: URL
    public let summary: String
    public let report: RedlineReport
}

public enum ReviewPipeline {
    /// Largest document we send in one request (characters of body text).
    public static let maxCharacters = 400_000

    public static func run(_ request: ReviewRequest, provider: PlanProvider,
                           progress: @escaping @Sendable (ReviewStage) -> Void) async throws -> ReviewOutcome {
        progress(.reading)
        let source = request.source
        guard source.pathExtension.lowercased() == "docx" else {
            throw ReviewError.unsupportedDocument("only Word documents (.docx) are supported.")
        }
        let document = try RedlineEngine.readText(of: source)
        guard !document.paragraphs.isEmpty else {
            throw ReviewError.unsupportedDocument("it doesn’t contain any text to review.")
        }
        guard document.characterCount <= maxCharacters else {
            throw ReviewError.unsupportedDocument("it’s too long to review in one pass.")
        }
        let destination = try outputURL(for: source, in: request.outputDirectory)

        progress(.reviewing)
        let prompt = Prompt.review(document: document, fileName: source.lastPathComponent,
                                   profile: request.profile, instructions: request.instructions)
        var plan = try await provider.requestPlan(system: Prompt.system, prompt: prompt)
        try Task.checkCancellation()

        // One chance for Claude to fix quotes that didn't match the document exactly.
        let unplaced = try RedlineEngine.unplaceable(plan, in: source).filter { $0.reason.contains("quoted text") }
        if !unplaced.isEmpty {
            progress(.refining)
            let fix = try await provider.requestPlan(system: Prompt.system,
                                                     prompt: Prompt.correction(failed: unplaced, plan: plan, document: document))
            try Task.checkCancellation()
            plan.edits.removeAll { e in unplaced.contains { $0.kind == .edit && $0.paragraph == e.paragraph && $0.excerpt == e.original } }
            plan.comments.removeAll { c in unplaced.contains { $0.kind == .comment && $0.paragraph == c.paragraph && $0.excerpt == c.quote } }
            plan.edits += fix.edits
            plan.comments += fix.comments
        }

        // The overall assessment also goes into the document, on its first paragraph.
        let summary = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, let first = document.paragraphs.first {
            let anchor = String(first.text.unicodeScalars.prefix(60))
            plan.comments.insert(.init(paragraph: first.index, quote: anchor, comment: "Overall review: \(summary)"), at: 0)
        }

        progress(.writing)
        let report = try RedlineEngine.apply(plan, to: source, writingTo: destination,
                                             options: RedlineOptions(author: request.author))
        return ReviewOutcome(output: destination, summary: summary, report: report)
    }

    /// "Memo.docx" → "Memo (Reviewed).docx", numbered if that name is taken. Never the original's path.
    public static func outputURL(for source: URL, in directory: URL?) throws -> URL {
        let fm = FileManager.default
        var folder = directory ?? source.deletingLastPathComponent()
        if !fm.isWritableFile(atPath: folder.path) {
            guard directory == nil, let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw ReviewError.outputLocation("The folder “\(folder.lastPathComponent)” can’t be written to. Choose a different save location in Settings.")
            }
            folder = documents
        }
        let base = source.deletingPathExtension().lastPathComponent
        for n in 1...999 {
            let name = n == 1 ? "\(base) (Reviewed).docx" : "\(base) (Reviewed \(n)).docx"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw ReviewError.outputLocation("Too many reviewed copies already exist in “\(folder.lastPathComponent)”.")
    }
}

extension RedlineEngine {
    /// Suggestions that couldn't be placed, without writing anything.
    public static func unplaceable(_ plan: ReviewPlan, in source: URL) throws -> [SkippedItem] {
        let loaded = try LoadedDocument(url: source)
        let session = RedlineSession(loaded: loaded, options: RedlineOptions(author: "Claude"))
        return session.resolve(plan).skipped
    }
}

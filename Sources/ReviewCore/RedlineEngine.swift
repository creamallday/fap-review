import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct RedlineOptions: Sendable {
    public var author: String
    public var date: Date

    public init(author: String, date: Date = Date()) {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = trimmed.isEmpty ? "Claude" : trimmed
        self.date = date
    }

    var initials: String {
        let letters = author.split(separator: " ").compactMap(\.first).map(String.init).joined()
        return String(letters.prefix(4)).uppercased()
    }

    var timestamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}

/// The document's body text as Claude sees it.
public struct DocumentText: Sendable {
    public struct Paragraph: Sendable {
        public let index: Int
        public let text: String
        public let style: String?
        public let inTable: Bool
        public let editable: Bool
    }
    public let paragraphs: [Paragraph]
    public var characterCount: Int { paragraphs.reduce(0) { $0 + $1.text.count } }
}

/// Turns a `ReviewPlan` into genuine Word revisions (`w:ins`/`w:del`) and comments in a copy
/// of the source document. The source file is never written to.
public enum RedlineEngine {

    // MARK: Reading

    public static func readText(of url: URL) throws -> DocumentText {
        let loaded = try LoadedDocument(url: url)
        let paragraphs = loaded.paragraphs.compactMap { p -> DocumentText.Paragraph? in
            let text = p.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(index: p.index, text: text, style: p.styleID, inTable: p.inTable,
                         editable: p.pieces.contains { $0.editable })
        }
        return DocumentText(paragraphs: paragraphs)
    }

    // MARK: Writing

    /// Applies `plan` to a copy of `source` saved at `destination`.
    /// The copy is verified before it is moved into place; on any failure nothing is left behind.
    @discardableResult
    public static func apply(_ plan: ReviewPlan, to source: URL, writingTo destination: URL,
                             options: RedlineOptions) throws -> RedlineReport {
        let src = source.resolvingSymlinksInPath().standardizedFileURL
        let dst = destination.resolvingSymlinksInPath().standardizedFileURL
        guard src.path != dst.path else {
            throw ReviewError.outputLocation("The reviewed copy can’t replace the original document.")
        }
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            throw ReviewError.outputLocation("A file named “\(dst.lastPathComponent)” already exists.")
        }

        let loaded = try LoadedDocument(url: src)
        var session = RedlineSession(loaded: loaded, options: options)
        let resolved = session.resolve(plan)
        try session.apply(resolved)

        if session.revisionIDs.isEmpty && session.commentIDs.isEmpty {
            if resolved.skipped.isEmpty {
                throw ReviewError.claude("Claude didn’t suggest any changes or comments for this document.")
            }
            throw ReviewError.verificationFailed(
                "None of Claude’s \(resolved.skipped.count) suggestions could be placed in the document reliably.")
        }

        let parts = try session.serialize()
        let temp = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString.prefix(8))-\(dst.lastPathComponent).partial")
        defer { try? FileManager.default.removeItem(at: temp) }
        try loaded.package.writeCopy(to: temp, replacements: parts.replacements, additions: parts.additions)

        try Verifier.verify(output: temp, original: loaded, session: session, expected: resolved)

        do {
            try FileManager.default.moveItem(at: temp, to: dst)
        } catch {
            throw ReviewError.outputLocation("Couldn’t save the reviewed copy to \(dst.deletingLastPathComponent().path).")
        }
        return RedlineReport(trackedChanges: session.revisionIDs.count,
                             comments: session.commentIDs.count,
                             skipped: resolved.skipped)
    }
}

// MARK: - Loaded document

final class LoadedDocument {
    let package: DocxPackage
    let mainPath: String
    let mainData: Data
    let xml: XMLDocument
    let names: WordNames
    let body: XMLElement
    let paragraphs: [ParagraphModel]
    let originalTexts: [[Unicode.Scalar]]

    init(url: URL) throws {
        package = try DocxPackage(url: url)
        mainPath = try package.mainDocumentPath()

        let types = try parseXML(try package.data("[Content_Types].xml"), part: "[Content_Types].xml")
        let partName = "/" + mainPath
        let override = types.rootElement()?.elementChildren.first {
            localName($0) == "Override" && $0.attr("PartName") == partName
        }
        guard let contentType = override?.attr("ContentType") else {
            throw ReviewError.unreadableDocument("it has no main document part.")
        }
        guard OOXML.mainContentTypes.contains(contentType) else {
            if contentType.contains("macroEnabled") {
                throw ReviewError.unsupportedDocument("it’s a macro-enabled document. Save it as a regular Word Document (.docx) and try again.")
            }
            throw ReviewError.unsupportedDocument("it isn’t a Word document.")
        }

        mainData = try package.data(mainPath)
        xml = try parseXML(mainData, part: mainPath)
        let names = WordNames(root: xml.rootElement())
        self.names = names
        guard let body = xml.rootElement()?.elementChildren.first(where: { names.local($0) == "body" }) else {
            throw ReviewError.unreadableDocument("the document has no body.")
        }
        self.body = body
        var scanner = ParagraphScanner(names: names)
        paragraphs = scanner.scanBody(body)
        originalTexts = paragraphs.map(\.text)
    }

    var mainDirectory: String {
        let parts = mainPath.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }

    func resolvePartTarget(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = mainDirectory.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = components.popLast() } else if piece != "." { components.append(String(piece)) }
        }
        return components.joined(separator: "/")
    }

    var mainRelsPath: String {
        let file = mainPath.split(separator: "/").last.map(String.init) ?? "document.xml"
        return (mainDirectory.isEmpty ? "" : mainDirectory + "/") + "_rels/\(file).rels"
    }
}

// MARK: - Resolution

struct ResolvedPlan {
    struct Edit {
        let paragraph: Int
        let hunks: [TextMatching.Hunk] // absolute paragraph offsets
        let comment: String?
        var extent: ClosedRange<Int> {
            hunks.map(\.deleted.lowerBound).min()!...hunks.map(\.deleted.upperBound).max()!
        }
    }
    struct Comment {
        let paragraph: Int
        let range: Range<Int>
        let text: String
    }
    var edits: [Edit] = []
    var comments: [Comment] = []
    var skipped: [SkippedItem] = []
}

struct RedlineSession {
    let loaded: LoadedDocument
    let options: RedlineOptions
    var names: WordNames { loaded.names }
    private(set) var revisionIDs: [String] = []
    private(set) var commentIDs: [String] = []
    private(set) var commentTexts: [(id: String, text: String)] = []
    private var nextRevisionID: Int
    private var nextCommentID: Int
    private var ourWrappers = Set<ObjectIdentifier>()

    init(loaded: LoadedDocument, options: RedlineOptions) {
        self.loaded = loaded
        self.options = options
        nextRevisionID = RedlineSession.maxNumericID(in: loaded, attribute: "id") + 1
        nextCommentID = RedlineSession.maxCommentID(in: loaded) + 1
    }

    // MARK: Resolve

    private func locate(_ quote: String, preferred paragraph: Int) -> (Int, Range<Int>)? {
        let paragraphs = loaded.paragraphs
        if paragraph >= 0 && paragraph < paragraphs.count,
           case .found(let r) = TextMatching.locate(quote, in: paragraphs[paragraph].text) {
            return (paragraph, r)
        }
        // The quote may carry the wrong paragraph number; accept it only if it is unique in the document.
        var hit: (Int, Range<Int>)?
        for p in paragraphs {
            switch TextMatching.locate(quote, in: p.text) {
            case .found(let r):
                if hit != nil { return nil }
                hit = (p.index, r)
            case .ambiguous: return nil
            case .notFound: continue
            }
        }
        return hit
    }

    private func failureReason(_ quote: String, paragraph: Int) -> String {
        if paragraph >= 0 && paragraph < loaded.paragraphs.count,
           case .ambiguous(let n) = TextMatching.locate(quote, in: loaded.paragraphs[paragraph].text) {
            return "The quoted text appears \(n) times in that paragraph, so its position is ambiguous."
        }
        return "The quoted text wasn’t found exactly in the document."
    }

    func resolve(_ plan: ReviewPlan) -> ResolvedPlan {
        var out = ResolvedPlan()
        var extents: [Int: [ClosedRange<Int>]] = [:]

        for edit in plan.edits {
            func skip(_ reason: String) {
                out.skipped.append(SkippedItem(kind: .edit, paragraph: edit.paragraph, excerpt: edit.original, reason: reason))
            }
            guard !edit.original.isEmpty else { skip("The suggestion didn’t quote any text to change."); continue }
            guard !edit.revised.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                skip("The suggestion would split a paragraph, which isn’t supported."); continue
            }
            guard let (p, range) = locate(edit.original, preferred: edit.paragraph) else {
                skip(failureReason(edit.original, paragraph: edit.paragraph)); continue
            }
            let model = loaded.paragraphs[p]
            let relative = TextMatching.diff(original: Array(model.text[range]), revised: Array(edit.revised.unicodeScalars))
            let comment = edit.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
            if relative.isEmpty {
                if let comment, !comment.isEmpty {
                    out.comments.append(.init(paragraph: p, range: range, text: comment))
                }
                continue
            }
            let hunks = relative.map {
                TextMatching.Hunk(deleted: ($0.deleted.lowerBound + range.lowerBound)..<($0.deleted.upperBound + range.lowerBound),
                                  inserted: $0.inserted)
            }
            guard hunks.allSatisfy({ canApply($0, in: model) }) else {
                skip("The text is inside a field, content control, existing tracked change or embedded object, so it can’t be changed safely.")
                continue
            }
            let resolved = ResolvedPlan.Edit(paragraph: p, hunks: hunks, comment: comment?.isEmpty == false ? comment : nil)
            if extents[p, default: []].contains(where: { $0.overlaps(resolved.extent) }) {
                skip("It overlaps another suggested change to the same text."); continue
            }
            extents[p, default: []].append(resolved.extent)
            out.edits.append(resolved)
        }

        for comment in plan.comments {
            let text = comment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            func skip(_ reason: String) {
                out.skipped.append(SkippedItem(kind: .comment, paragraph: comment.paragraph, excerpt: comment.quote, reason: reason))
            }
            guard !text.isEmpty else { continue }
            guard let (p, range) = locate(comment.quote, preferred: comment.paragraph) else {
                skip(failureReason(comment.quote, paragraph: comment.paragraph)); continue
            }
            let model = loaded.paragraphs[p]
            // Snap boundaries that fall inside unsplittable text (fields, objects) outward.
            var lower = range.lowerBound, upper = range.upperBound
            if let piece = model.piece(containingInterior: lower), !piece.editable { lower = piece.start }
            if let piece = model.piece(containingInterior: upper), !piece.editable { upper = piece.end }
            guard !model.pieces(in: lower..<upper).isEmpty else {
                skip("The quoted text couldn’t be anchored."); continue
            }
            out.comments.append(.init(paragraph: p, range: lower..<upper, text: text))
        }
        return out
    }

    private func canApply(_ hunk: TextMatching.Hunk, in model: ParagraphModel) -> Bool {
        if !hunk.deleted.isEmpty {
            guard model.isEditable(hunk.deleted) else { return false }
        }
        if !hunk.inserted.isEmpty && hunk.deleted.isEmpty {
            return insertionAnchor(at: hunk.deleted.lowerBound, in: model) != nil
        }
        return true
    }

    private enum Anchor { case after(Piece), before(Piece), inside(Piece) }

    private func insertionAnchor(at offset: Int, in model: ParagraphModel) -> Anchor? {
        if let p = model.piece(containingInterior: offset) { return p.editable ? .inside(p) : nil }
        let left = model.pieces.last(where: { $0.end == offset && $0.length > 0 && $0.editable })
        let right = model.pieces.first(where: { $0.start == offset && $0.length > 0 && $0.editable })
        // Text added just after a hyperlink belongs outside the link, so prefer the next plain run.
        if let left, let right, left.node.parent !== right.node.parent, left.node.parent !== model.element {
            return .before(right)
        }
        if let left { return .after(left) }
        if let right { return .before(right) }
        return nil
    }

    // MARK: Apply

    mutating func apply(_ plan: ResolvedPlan) throws {
        let byParagraph = Dictionary(grouping: plan.edits, by: \.paragraph)
        let commentsByParagraph = Dictionary(grouping: plan.comments, by: \.paragraph)
        let touched = Set(byParagraph.keys).union(commentsByParagraph.keys).sorted()
        var scanner = ParagraphScanner(names: names)

        for p in touched {
            let model = loaded.paragraphs[p]
            let edits = (byParagraph[p] ?? []).sorted { $0.extent.lowerBound < $1.extent.lowerBound }
            let comments = commentsByParagraph[p] ?? []

            // 1. Make every boundary we need fall between runs.
            var boundaries = Set<Int>()
            for e in edits { for h in e.hunks { boundaries.insert(h.deleted.lowerBound); boundaries.insert(h.deleted.upperBound) } }
            for c in comments { boundaries.insert(c.range.lowerBound); boundaries.insert(c.range.upperBound) }
            for b in boundaries.sorted() {
                guard let piece = model.piece(containingInterior: b) else { continue }
                guard ParagraphScanner.splitRun(piece, at: b, names: names) else {
                    throw ReviewError.verificationFailed("Internal error: couldn’t split text in paragraph \(p).")
                }
                scanner.rescan(model)
            }

            // 2. Tracked changes.
            var editSpans: [(ResolvedPlan.Edit, XMLElement, XMLElement)] = []
            for edit in edits {
                var first: XMLElement?
                var last: XMLElement?
                for hunk in edit.hunks {
                    let (f, l) = try applyHunk(hunk, in: model)
                    if first == nil { first = f }
                    last = l
                }
                if let first, let last { editSpans.append((edit, first, last)) }
            }

            // 3. Comments: attached to edits, then standalone.
            for (edit, first, last) in editSpans {
                if let text = edit.comment { addCommentMarkers(text: text, from: first, to: last) }
            }
            for c in comments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                let pieces = model.pieces(in: c.range)
                guard let first = pieces.first, let last = pieces.last else { continue }
                // Never put comment marks inside a field's result; span the whole field instead.
                var from = outermost(first.node), to = outermost(last.node)
                if first.inFieldResult, let bounds = ParagraphScanner.fieldBounds(of: first.node, names: names) { from = bounds.begin }
                if last.inFieldResult, let bounds = ParagraphScanner.fieldBounds(of: last.node, names: names) { to = bounds.end }
                addCommentMarkers(text: c.text, from: from, to: to)
            }
        }
    }

    private func outermost(_ node: XMLElement) -> XMLElement {
        if let parent = node.parent as? XMLElement, ourWrappers.contains(ObjectIdentifier(parent)) { return parent }
        return node
    }

    private mutating func revisionElement(_ kind: String) -> XMLElement {
        let id = String(nextRevisionID)
        nextRevisionID += 1
        revisionIDs.append(id)
        let e = names.element(kind, attributes: [("id", id), ("author", options.author), ("date", options.timestamp)])
        ourWrappers.insert(ObjectIdentifier(e))
        return e
    }

    /// Returns the first and last element the hunk produced, for comment anchoring.
    private mutating func applyHunk(_ hunk: TextMatching.Hunk, in model: ParagraphModel) throws -> (XMLElement, XMLElement) {
        var wrappers: [XMLElement] = []
        let deleted = hunk.deleted.isEmpty ? [] : model.pieces(in: hunk.deleted)
        if !hunk.deleted.isEmpty {
            guard deleted.allSatisfy({ $0.editable && $0.start >= hunk.deleted.lowerBound && $0.end <= hunk.deleted.upperBound }) else {
                throw ReviewError.verificationFailed("Internal error: a deletion didn’t align with the document’s runs.")
            }
            // Group runs that are adjacent siblings so each group becomes one w:del.
            var groups: [[XMLElement]] = []
            for piece in deleted {
                let run = piece.node
                if let prev = groups.last?.last, prev.parent === run.parent, prev.index + 1 == run.index {
                    groups[groups.count - 1].append(run)
                } else {
                    groups.append([run])
                }
            }
            for group in groups {
                guard let parent = group[0].parent as? XMLElement else { continue }
                let del = revisionElement("del")
                parent.insertChild(del, at: group[0].index)
                for run in group {
                    run.detach()
                    // Replace rather than rename: renaming a parsed element mangles its prefix on Linux.
                    for c in run.elementChildren where names.local(c) == "t" {
                        run.replaceChild(at: c.index, with: names.textElement("delText", c.stringValue ?? ""))
                    }
                    del.addChild(run)
                }
                wrappers.append(del)
            }
        }

        guard !hunk.inserted.isEmpty else { return (wrappers.first!, wrappers.last!) }

        let template: XMLElement
        let place: (XMLElement) -> Void
        if let lastDel = wrappers.last {
            template = deleted[0].node
            place = { lastDel.insertSibling($0, before: false) }
        } else {
            switch insertionAnchor(at: hunk.deleted.lowerBound, in: model) {
            case .after(let left)?:
                template = left.node
                let target = outermost(left.node)
                place = { target.insertSibling($0, before: false) }
            case .before(let right)?:
                template = right.node
                let target = outermost(right.node)
                place = { target.insertSibling($0, before: true) }
            default:
                throw ReviewError.verificationFailed("Internal error: no place to insert text.")
            }
        }
        let ins = revisionElement("ins")
        ins.addChild(makeRun(text: hunk.inserted, formattedLike: template))
        place(ins)
        return (wrappers.first ?? ins, ins)
    }

    private func makeRun(text: String, formattedLike template: XMLElement) -> XMLElement {
        let run = names.element("r")
        if let rPr = template.elementChildren.first(where: { names.local($0) == "rPr" }).map(cloneElement) {
            for c in rPr.elementChildren where names.local(c) == "rPrChange" { c.detach() }
            run.addChild(rPr)
        }
        let pieces = text.split(separator: "\t", omittingEmptySubsequences: false)
        for (i, piece) in pieces.enumerated() {
            if i > 0 { run.addChild(names.element("tab")) }
            if !piece.isEmpty { run.addChild(names.textElement("t", String(piece))) }
        }
        return run
    }

    private mutating func addCommentMarkers(text: String, from first: XMLElement, to last: XMLElement) {
        let id = String(nextCommentID)
        nextCommentID += 1
        commentIDs.append(id)
        commentTexts.append((id, text))
        first.insertSibling(names.element("commentRangeStart", attributes: [("id", id)]), before: true)
        let end = names.element("commentRangeEnd", attributes: [("id", id)])
        last.insertSibling(end, before: false)
        let ref = names.element("r")
        ref.addChild(names.element("commentReference", attributes: [("id", id)]))
        end.insertSibling(ref, before: false)
    }

    // MARK: Serialize

    struct Parts {
        var replacements: [String: Data] = [:]
        var additions: [(String, Data)] = []
    }

    func serialize() throws -> Parts {
        var parts = Parts()
        parts.replacements[loaded.mainPath] = serializeXML(loaded.xml, originalData: loaded.mainData)
        guard !commentTexts.isEmpty else { return parts }

        let pkg = loaded.package
        let relsPath = loaded.mainRelsPath
        let relsData = pkg.has(relsPath) ? try pkg.data(relsPath) : nil
        let rels = try relsData.map { try parseXML($0, part: relsPath) }
            ?? XMLDocument(rootElement: {
                let r = XMLElement(name: "Relationships")
                r.addNamespace(XMLNode.namespace(withName: "", stringValue: OOXML.relationshipsNamespace) as! XMLNode)
                return r
            }())
        let relRoot = rels.rootElement()!
        let existingCommentsRel = relRoot.elementChildren.first {
            localName($0) == "Relationship" && $0.attr("Type") == OOXML.commentsRel && $0.attr("TargetMode") != "External"
        }

        let commentsPath: String
        let commentsXML: XMLDocument
        var commentsOriginal: Data?
        if let rel = existingCommentsRel, let target = rel.attr("Target"), pkg.has(loaded.resolvePartTarget(target)) {
            commentsPath = loaded.resolvePartTarget(target)
            commentsOriginal = try pkg.data(commentsPath)
            commentsXML = try parseXML(commentsOriginal!, part: commentsPath)
        } else {
            commentsPath = loaded.resolvePartTarget("comments.xml")
            guard !pkg.has(commentsPath) else {
                throw ReviewError.unsupportedDocument("it contains an unlinked comments part.")
            }
            let root = XMLElement(name: "w:comments")
            root.addNamespace(XMLNode.namespace(withName: "w", stringValue: OOXML.wordNamespace) as! XMLNode)
            commentsXML = XMLDocument(rootElement: root)
            commentsXML.isStandalone = true

            var maxID = 0
            for r in relRoot.elementChildren {
                if let id = r.attr("Id"), id.hasPrefix("rId"), let n = Int(id.dropFirst(3)) { maxID = max(maxID, n) }
            }
            let rel = XMLElement(name: "Relationship")
            rel.setAttr("Id", "rId\(maxID + 1)")
            rel.setAttr("Type", OOXML.commentsRel)
            rel.setAttr("Target", "comments.xml")
            relRoot.addChild(rel)

            let typesData = try pkg.data("[Content_Types].xml")
            let types = try parseXML(typesData, part: "[Content_Types].xml")
            let override = XMLElement(name: "Override")
            override.setAttr("PartName", "/" + commentsPath)
            override.setAttr("ContentType", OOXML.commentsContentType)
            types.rootElement()!.addChild(override)
            parts.replacements["[Content_Types].xml"] = serializeXML(types, originalData: typesData)
            if relsData != nil {
                parts.replacements[relsPath] = serializeXML(rels, originalData: relsData)
            } else {
                parts.additions.append((relsPath, serializeXML(rels, originalData: nil)))
            }
        }

        let cNames = WordNames(root: commentsXML.rootElement())
        for (id, text) in commentTexts {
            let comment = cNames.element("comment", attributes: [
                ("id", id), ("author", options.author), ("date", options.timestamp), ("initials", options.initials),
            ])
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for (i, line) in (lines.isEmpty ? [text] : lines).enumerated() {
                let p = cNames.element("p")
                if i == 0 {
                    let ref = cNames.element("r")
                    ref.addChild(cNames.element("annotationRef"))
                    p.addChild(ref)
                }
                let r = cNames.element("r")
                r.addChild(cNames.textElement("t", line))
                p.addChild(r)
                comment.addChild(p)
            }
            commentsXML.rootElement()!.addChild(comment)
        }
        let data = serializeXML(commentsXML, originalData: commentsOriginal ?? Data("standalone=\"yes\"".utf8))
        if commentsOriginal != nil { parts.replacements[commentsPath] = data } else { parts.additions.append((commentsPath, data)) }
        return parts
    }

    // MARK: IDs

    private static func numbers(in data: Data, attribute: String) -> [Int] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        let pattern = ":\(attribute)=\"(-?[0-9]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).flatMap { Int(s[$0]) }
        }
    }

    /// Revision ids must be unique across the whole package, so look at every Word part.
    static func maxNumericID(in loaded: LoadedDocument, attribute: String) -> Int {
        var maxID = numbers(in: loaded.mainData, attribute: attribute).max() ?? 0
        let dir = loaded.mainDirectory
        for path in loaded.package.entryPaths where path.hasSuffix(".xml") && path.hasPrefix(dir) && path != loaded.mainPath {
            if let data = try? loaded.package.data(path) {
                maxID = max(maxID, numbers(in: data, attribute: attribute).max() ?? 0)
            }
        }
        return maxID
    }

    static func maxCommentID(in loaded: LoadedDocument) -> Int {
        var maxID = -1
        for path in loaded.package.entryPaths where path.hasSuffix("comments.xml") {
            if let data = try? loaded.package.data(path) { maxID = max(maxID, numbers(in: data, attribute: "id").max() ?? -1) }
        }
        let s = String(data: loaded.mainData, encoding: .utf8) ?? ""
        if let regex = try? NSRegularExpression(pattern: "comment(?:RangeStart|RangeEnd|Reference) [^>]*:id=\"([0-9]+)\"") {
            for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s), let n = Int(s[r]) { maxID = max(maxID, n) }
            }
        }
        return maxID
    }
}

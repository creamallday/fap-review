import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A failed check that points at one paragraph. The engine can leave out the suggestions touching
/// that paragraph and try again, and the details help diagnose the cause.
struct VerificationFailure: Error {
    var paragraph: Int
    var message: String
    var detail: String

    var reviewError: ReviewError { .verificationFailed(message + "\n\n" + detail) }

    /// Describes where two paragraph texts first differ, with invisible characters spelled out.
    static func describe(expected: [Unicode.Scalar], actual: [Unicode.Scalar]) -> String {
        var i = 0
        while i < expected.count && i < actual.count && expected[i] == actual[i] { i += 1 }
        func show(_ a: [Unicode.Scalar]) -> String {
            let lo = max(0, i - 30), hi = min(a.count, i + 30)
            return a[lo..<hi].map { s -> String in
                (s.value >= 0x20 && s.value < 0x7F) || s.value == 0x2019 ? String(s) : String(format: "<U+%04X>", s.value)
            }.joined()
        }
        return "first difference at character \(i) (expected \(expected.count) characters, found \(actual.count))\n"
            + "expected: …\(show(expected))…\nfound:    …\(show(actual))…"
    }
}

/// Re-reads a freshly written copy from disk and proves it is what we meant to produce.
enum Verifier {
    /// Test hook: paragraphs for which the next check reports a failure, once each.
    nonisolated(unsafe) static var injectedFailures: Set<Int> = []

    static func verify(output: URL, original: LoadedDocument, session: RedlineSession, expected: ResolvedPlan) throws {
        func fail(_ detail: String) -> ReviewError { .verificationFailed(detail) }

        let written: DocxPackage
        do { written = try DocxPackage(url: output) } catch { throw fail("The new file couldn’t be reopened.") }

        // 1. Package: every part we didn't mean to change is byte-identical.
        let changed: Set<String> = [original.mainPath, "[Content_Types].xml", original.mainRelsPath]
        for path in original.package.entryPaths {
            guard written.has(path) else { throw fail("The part \(path) went missing.") }
            if changed.contains(path) || path.hasSuffix("comments.xml") { continue }
            if try written.data(path) != original.package.data(path) { throw fail("The part \(path) changed unexpectedly.") }
        }

        // 2. Every XML part we touched still parses.
        let mainData = try written.data(original.mainPath)
        let xml = try parseXML(mainData, part: original.mainPath)
        for path in written.entryPaths where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            if changed.contains(path) || path.hasSuffix("comments.xml") {
                _ = try parseXML(try written.data(path), part: path)
            }
        }

        let names = WordNames(root: xml.rootElement())
        guard let body = xml.rootElement()?.elementChildren.first(where: { names.local($0) == "body" }) else {
            throw fail("The document body went missing.")
        }
        let ours = Set(session.revisionIDs)
        let touched = Set(expected.edits.map(\.paragraph))
        if let p = Verifier.injectedFailures.sorted().first(where: { touched.contains($0) }) {
            Verifier.injectedFailures.remove(p)
            throw VerificationFailure(paragraph: p, message: "Injected failure in paragraph \(p).", detail: "test")
        }

        // 3. Rejecting our revisions restores the original text exactly, paragraph by paragraph.
        var rejecting = ParagraphScanner(names: names, view: RevisionView(
            showInsertion: { !ours.contains($0 ?? "") }, showDeletion: { ours.contains($0 ?? "") }))
        let rejectedModels = rejecting.scanBody(body)
        let rejected = rejectedModels.map(\.text)
        guard rejected.count == original.originalTexts.count else { throw fail("The paragraph count changed.") }
        for (i, text) in rejected.enumerated() where text != original.originalTexts[i] {
            throw VerificationFailure(
                paragraph: i, message: "Paragraph \(i) no longer matches the original when the changes are rejected.",
                detail: VerificationFailure.describe(expected: original.originalTexts[i], actual: text)
                    + "\nparagraph XML: " + String(rejectedModels[i].element.xmlString.prefix(2500)))
        }

        // 4. Accepting our revisions produces exactly the intended text.
        var accepting = ParagraphScanner(names: names, view: RevisionView(
            showInsertion: { _ in true }, showDeletion: { _ in false }))
        let acceptedModels = accepting.scanBody(body)
        let accepted = acceptedModels.map(\.text)
        // Apply every hunk of a paragraph from the end backwards so earlier offsets stay valid,
        // regardless of which suggestion each hunk came from.
        var intended = original.originalTexts
        let hunksByParagraph = Dictionary(grouping: expected.edits.flatMap { edit in edit.hunks.map { (edit.paragraph, $0) } },
                                          by: { $0.0 })
        for (paragraph, pairs) in hunksByParagraph {
            let ordered = pairs.map(\.1).sorted {
                ($0.deleted.lowerBound, $0.deleted.upperBound) > ($1.deleted.lowerBound, $1.deleted.upperBound)
            }
            for hunk in ordered {
                guard paragraph < intended.count, hunk.deleted.upperBound <= intended[paragraph].count else {
                    throw fail("Internal error: a change pointed outside paragraph \(paragraph).")
                }
                intended[paragraph].replaceSubrange(hunk.deleted, with: Array(hunk.inserted.unicodeScalars))
            }
        }
        guard accepted.count == intended.count else { throw fail("The paragraph count changed.") }
        for (i, text) in accepted.enumerated() where text != intended[i] {
            throw VerificationFailure(
                paragraph: i, message: "Paragraph \(i) doesn’t read as intended when the changes are accepted.",
                detail: VerificationFailure.describe(expected: intended[i], actual: text)
                    + "\nparagraph XML: " + String(acceptedModels[i].element.xmlString.prefix(2500)))
        }

        // 5. Each revision and comment is present exactly once and fully linked.
        var revisionCount: [String: Int] = [:]
        var markers: [String: [String: Int]] = [:]
        func visit(_ e: XMLElement) {
            if let local = names.local(e) {
                switch local {
                case "ins", "del":
                    if let id = e.attr(names.q("id")), ours.contains(id) { revisionCount[id, default: 0] += 1 }
                case "commentRangeStart", "commentRangeEnd", "commentReference":
                    if let id = e.attr(names.q("id")) { markers[id, default: [:]][local, default: 0] += 1 }
                default: break
                }
            }
            e.elementChildren.forEach(visit)
        }
        visit(body)
        for id in session.revisionIDs where revisionCount[id] != 1 {
            throw fail("Tracked change \(id) is missing or duplicated.")
        }
        if !session.commentIDs.isEmpty {
            let commentsPath = written.entryPaths.first { $0.hasSuffix("comments.xml") && $0.hasPrefix(original.mainDirectory) }
            guard let commentsPath else { throw fail("The comments part is missing.") }
            let comments = try parseXML(try written.data(commentsPath), part: commentsPath)
            let cNames = WordNames(root: comments.rootElement())
            let stored = Set(comments.rootElement()?.elementChildren.compactMap { $0.attr(cNames.q("id")) } ?? [])
            for id in session.commentIDs {
                guard stored.contains(id) else { throw fail("Comment \(id) has no text.") }
                for kind in ["commentRangeStart", "commentRangeEnd", "commentReference"] where markers[id]?[kind] != 1 {
                    throw fail("Comment \(id) isn’t anchored correctly.")
                }
            }
            let types = try written.data("[Content_Types].xml")
            guard String(decoding: types, as: UTF8.self).contains(OOXML.commentsContentType) else {
                throw fail("The comments part isn’t registered.")
            }
            let rels = try written.data(original.mainRelsPath)
            guard String(decoding: rels, as: UTF8.self).contains(OOXML.commentsRel) else {
                throw fail("The comments part isn’t linked to the document.")
            }
        }
    }
}

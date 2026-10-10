import Foundation
import XCTest
import ZIPFoundation
@testable import ReviewCore
#if canImport(FoundationXML)
import FoundationXML
#endif

final class RedlineEngineTests: XCTestCase {
    var workdir: URL!

    override func setUpWithError() throws {
        workdir = FileManager.default.temporaryDirectory.appendingPathComponent("redline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workdir)
    }

    func fixture(_ name: String) throws -> URL {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "docx"))
        let dst = workdir.appendingPathComponent("\(name).docx")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    func part(_ path: String, of url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        var data = Data()
        _ = try archive.extract(try XCTUnwrap(archive[path])) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    func testReadsVisibleTextIncludingTablesAndLinks() throws {
        let text = try RedlineEngine.readText(of: try fixture("basic-memo"))
        let strings = text.paragraphs.map(\.text)
        XCTAssertEqual(strings.first, "MEMORANDUM")
        XCTAssertTrue(strings.contains("Additional detail is available on the DCS fleet page. Funding has been identified in the current budget."))
        XCTAssertTrue(strings.contains("8,450"))
    }

    func testFieldsRevisionsAndControlsAreReadOnly() throws {
        let text = try RedlineEngine.readText(of: try fixture("complex-memo"))
        let byText = Dictionary(text.paragraphs.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotNil(byText["This plan was printed on October 10, 2026 and supersedes the prior submission."])
        XCTAssertNotNil(byText["The department will dispose of the replaced units through state surplus auction after delivery of the new vehicles."])
        XCTAssertNotNil(byText["Requested funding: $96,400 from the Motor Vehicle Account."])
        XCTAssertNotNil(byText["Line one of an address block\nLine two after a manual line break."])
    }

    func testAppliesTrackedChangesAndCommentsAndLeavesOriginalUntouched() throws {
        let source = try fixture("basic-memo")
        let before = try Data(contentsOf: source)
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "s", edits: [
            .init(paragraph: 6, original: "Both vehicles is used daily", revised: "Both vehicles are used daily"),
            .init(paragraph: 8, original: "which we believe demonstrates \"high utilization\" of the existing fleet",
                  revised: "which is below the utilization threshold", comment: "Below threshold."),
            .init(paragraph: 10, original: "DCS fleet page.", revised: "DCS fleet page and Attachment A."),
        ], comments: [
            .init(paragraph: 9, quote: "An exemption from the ZEV mandate is therefore requested.", comment: "Unsubstantiated."),
        ])
        let report = try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "Tester"))

        XCTAssertEqual(try Data(contentsOf: source), before, "the original must never change")
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.comments, 2)
        XCTAssertGreaterThanOrEqual(report.trackedChanges, 4)

        let xml = try part("word/document.xml", of: out)
        XCTAssertTrue(xml.contains("<w:delText xml:space=\"preserve\">is</w:delText>"))
        XCTAssertTrue(xml.contains("w:author=\"Tester\""))
        XCTAssertFalse(xml.contains("w:w:"))
        XCTAssertEqual(xml.components(separatedBy: "<w:commentRangeStart").count - 1, 2)
        let comments = try part("word/comments.xml", of: out)
        XCTAssertTrue(comments.contains("Unsubstantiated."))
        XCTAssertTrue(try part("[Content_Types].xml", of: out).contains("comments+xml"))
        XCTAssertTrue(try part("word/_rels/document.xml.rels", of: out).contains("relationships/comments"))

        // The inserted text after the link stays outside the hyperlink.
        let link = try XCTUnwrap(xml.range(of: "<w:hyperlink")).lowerBound
        let linkEnd = try XCTUnwrap(xml.range(of: "</w:hyperlink>", range: link..<xml.endIndex)).lowerBound
        XCTAssertFalse(xml[link..<linkEnd].contains("Attachment A"))
    }

    func testUnsafeAndAmbiguousEditsAreReportedNotApplied() throws {
        let source = try fixture("complex-memo")
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "", edits: [
            .init(paragraph: 6, original: "October 10, 2026", revised: "1 January 2026"),          // field result
            .init(paragraph: 8, original: "state surplus auction", revised: "public auction"),       // earlier revision
            .init(paragraph: 9, original: "$96,400", revised: "$98,000"),                            // content control
            .init(paragraph: 11, original: "the vehicle", revised: "the truck"),                     // ambiguous
            .init(paragraph: 5, original: "nonexistent words", revised: "x"),                        // not found
            .init(paragraph: 5, original: "6,100 miles annually", revised: "6,100 miles per year"),  // fine
            .init(paragraph: 5, original: "miles annually, well", revised: "miles yearly, well"),    // overlaps
        ])
        let report = try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "T"))
        XCTAssertEqual(report.skipped.count, 6)
        XCTAssertEqual(report.trackedChanges, 2)
        XCTAssertTrue(report.skipped.contains { $0.reason.contains("ambiguous") })
        XCTAssertTrue(report.skipped.contains { $0.reason.contains("overlaps") })
        XCTAssertTrue(report.skipped.contains { $0.reason.contains("wasn’t found") })
    }

    func testCommentOnFieldSpansWholeField() throws {
        let source = try fixture("complex-memo")
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "", comments: [.init(paragraph: 6, quote: "October 10", comment: "Check date")])
        try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "T"))
        let xml = try part("word/document.xml", of: out)
        let start = try XCTUnwrap(xml.range(of: "<w:commentRangeStart")).lowerBound
        let begin = try XCTUnwrap(xml.range(of: "fldCharType=\"begin\"")).lowerBound
        let endMark = try XCTUnwrap(xml.range(of: "fldCharType=\"end\"")).lowerBound
        let rangeEnd = try XCTUnwrap(xml.range(of: "<w:commentRangeEnd")).lowerBound
        XCTAssertLessThan(start, begin)
        XCTAssertGreaterThan(rangeEnd, endMark)
    }

    func testAppendsToExistingCommentsWithoutDisturbingThem() throws {
        let source = try fixture("complex-memo")
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "", comments: [.init(paragraph: 10, quote: "Eureka field office", comment: "New note")])
        try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "T"))
        let comments = try part("word/comments.xml", of: out)
        XCTAssertTrue(comments.contains("Confirm the office location."))
        XCTAssertTrue(comments.contains("New note"))
        XCTAssertTrue(comments.contains("w:id=\"1\""), "new comment ids continue after existing ones")
    }

    func testRefusesToOverwrite() throws {
        let source = try fixture("basic-memo")
        let plan = ReviewPlan(summary: "", edits: [.init(paragraph: 6, original: "is used", revised: "are used")])
        XCTAssertThrowsError(try RedlineEngine.apply(plan, to: source, writingTo: source, options: RedlineOptions(author: "T")))
        let existing = workdir.appendingPathComponent("exists.docx")
        try Data("x".utf8).write(to: existing)
        XCTAssertThrowsError(try RedlineEngine.apply(plan, to: source, writingTo: existing, options: RedlineOptions(author: "T")))
        XCTAssertEqual(try Data(contentsOf: existing), Data("x".utf8))
    }

    func testNothingPlaceableProducesNoFile() throws {
        let source = try fixture("basic-memo")
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "", edits: [.init(paragraph: 1, original: "not in document", revised: "x")])
        XCTAssertThrowsError(try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "T")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workdir.path).filter { $0.hasSuffix(".partial") }, [])
    }

    func testUnchangedPartsAreByteIdentical() throws {
        let source = try fixture("complex-memo")
        let out = workdir.appendingPathComponent("out.docx")
        let plan = ReviewPlan(summary: "", edits: [.init(paragraph: 12, original: "Line two after", revised: "Second line after")])
        try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "T"))
        for path in ["word/styles.xml", "word/footnotes.xml", "word/settings.xml", "docProps/core.xml"] {
            XCTAssertEqual(try part(path, of: out), try part(path, of: source), path)
        }
    }

    func testRejectsNonWordFiles() throws {
        let bogus = workdir.appendingPathComponent("bogus.docx")
        try Data("not a zip".utf8).write(to: bogus)
        XCTAssertThrowsError(try RedlineEngine.readText(of: bogus))
    }
}

final class MultiEditRegressionTests: XCTestCase {
    /// Several edits in one paragraph, listed out of document order, once made the integrity check
    /// compare against the wrong expected text and reject correct output.
    func testSeveralEditsInOneParagraphOutOfOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("memo.docx")
        try FileManager.default.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic-memo", withExtension: "docx")), to: source)
        let plan = ReviewPlan(summary: "", edits: [
            .init(paragraph: 9, original: "An exemption from the ZEV mandate is therefore requested.", revised: "A ZEV exemption is requested."),
            .init(paragraph: 9, original: "gasoline-powered", revised: "gasoline- or hybrid-powered"),
            .init(paragraph: 9, original: "not available at all monitoring stations", revised: "unavailable at several monitoring stations"),
        ])
        let out = dir.appendingPathComponent("out.docx")
        let report = try RedlineEngine.apply(plan, to: source, writingTo: out, options: RedlineOptions(author: "Chris Holm"))
        XCTAssertEqual(report.skipped, [])
        XCTAssertGreaterThanOrEqual(report.trackedChanges, 3)
    }
}

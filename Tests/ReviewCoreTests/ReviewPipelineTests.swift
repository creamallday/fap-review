import XCTest
@testable import ReviewCore

/// Stands in for Claude: first reply has a bad quote, the correction fixes it.
final class ScriptedProvider: PlanProvider, @unchecked Sendable {
    var replies: [ReviewPlan]
    var prompts: [String] = []
    init(_ replies: [ReviewPlan]) { self.replies = replies }
    func requestPlan(system: String, prompt: String) async throws -> ReviewPlan {
        prompts.append(prompt)
        return replies.removeFirst()
    }
}

final class ReviewPipelineTests: XCTestCase {
    func testEndToEndWithCorrectionRound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Memo.docx")
        try FileManager.default.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic-memo", withExtension: "docx")), to: source)

        let provider = ScriptedProvider([
            ReviewPlan(summary: "Return for revision.", edits: [
                .init(paragraph: 6, original: "Both vehicle is used", revised: "Both vehicles are used"),
            ], comments: [.init(paragraph: 9, quote: "ZEV mandate", comment: "Unsupported exemption.")]),
            ReviewPlan(summary: "", edits: [
                .init(paragraph: 6, original: "Both vehicles is used", revised: "Both vehicles are used"),
            ]),
        ])
        let request = ReviewRequest(source: source, profile: .fapScreening, instructions: "Focus on utilization.", author: "Claude")
        let outcome = try await ReviewPipeline.run(request, provider: provider, progress: { _ in })

        XCTAssertEqual(outcome.output.lastPathComponent, "Memo (Reviewed).docx")
        XCTAssertEqual(outcome.report.skipped, [])
        XCTAssertEqual(outcome.report.comments, 2) // summary + one remark
        XCTAssertEqual(provider.prompts.count, 2)
        XCTAssertTrue(provider.prompts[0].contains("Focus on utilization."))
        XCTAssertTrue(provider.prompts[0].contains("[P6] The Department of Coastal Surveys"))
        XCTAssertTrue(provider.prompts[1].contains("Both vehicle is used"))

        // A second review gets a new name instead of overwriting.
        XCTAssertEqual(try ReviewPipeline.outputURL(for: source, in: nil).lastPathComponent, "Memo (Reviewed 2).docx")
    }

    func testProfilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(directory: dir)
        XCTAssertEqual(store.load(), [.fapScreening])
        let custom = [ReviewProfile(name: "Lease requests", criteria: "Check lease terms.")]
        try store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }
}

final class CriteriaDocumentTests: XCTestCase {
    func testOldProfilesWithoutDocumentsStillLoad() throws {
        let json = #"[{"id":"6F0C3C1E-5D5B-4C55-9C6A-0F3A2E7B1D01","name":"Old","criteria":"Check things."}]"#
        let profiles = try JSONDecoder().decode([ReviewProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles.first?.documents, [])
    }

    func testImportsTextAndWordFilesAndRejectsOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("criteria-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let txt = dir.appendingPathComponent("SAM 4121 notes.txt")
        try "Utilization must be documented.".write(to: txt, atomically: true, encoding: .utf8)
        let doc = try CriteriaImporter.document(from: txt)
        XCTAssertEqual(doc.name, "SAM 4121 notes")
        XCTAssertEqual(doc.text, "Utilization must be documented.")

        let word = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic-memo", withExtension: "docx"))
        XCTAssertTrue(try CriteriaImporter.document(from: word).text.contains("Fleet Acquisition Plan"))

        let empty = dir.appendingPathComponent("empty.txt")
        try "  \n".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CriteriaImporter.document(from: empty))
        XCTAssertThrowsError(try CriteriaImporter.document(from: dir.appendingPathComponent("sheet.xlsx")))

        let big = dir.appendingPathComponent("big.txt")
        try String(repeating: "a", count: CriteriaImporter.maxCharacters + 1).write(to: big, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CriteriaImporter.document(from: big))
    }

    func testPromptIncludesAttachedDocuments() {
        var profile = ReviewProfile(name: "P", criteria: "Base criteria.")
        profile.documents = [CriteriaDocument(name: "Fleet Policy 2026", text: "Vehicles must be ZEV.")]
        let text = DocumentText(paragraphs: [.init(index: 0, text: "Hello", style: nil, inTable: false, editable: true)])
        let prompt = Prompt.review(document: text, fileName: "m.docx", profile: profile, instructions: "")
        XCTAssertTrue(prompt.contains("Base criteria."))
        XCTAssertTrue(prompt.contains("“Fleet Policy 2026”"))
        XCTAssertTrue(prompt.contains("Vehicles must be ZEV."))
    }

    func testAuthorAppearsOnChangesAndInitials() {
        let options = RedlineOptions(author: "Chris Holm")
        XCTAssertEqual(options.author, "Chris Holm")
        XCTAssertEqual(options.initials, "CH")
    }
}

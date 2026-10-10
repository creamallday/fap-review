import XCTest
@testable import ReviewCore

final class TextMatchingTests: XCTestCase {
    func s(_ x: String) -> [Unicode.Scalar] { Array(x.unicodeScalars) }

    func testTypographyInsensitiveMatch() {
        XCTAssertEqual(TextMatching.locate("the department's \"plan\"", in: s("Per the department’s “plan” today")), .found(4..<27))
        XCTAssertEqual(TextMatching.locate("plan", in: s("plan and plan")), .ambiguous(2))
        XCTAssertEqual(TextMatching.locate("missing", in: s("plan")), .notFound)
    }

    func testWordDiffIsMinimal() {
        let hunks = TextMatching.diff(original: s("Both vehicles is used daily"), revised: s("Both vehicles are used daily"))
        XCTAssertEqual(hunks, [.init(deleted: 14..<16, inserted: "are")])
    }

    func testPureInsertion() {
        let hunks = TextMatching.diff(original: s("fleet page."), revised: s("fleet page and Attachment A."))
        XCTAssertEqual(hunks, [.init(deleted: 10..<10, inserted: " and Attachment A")])
    }

    func testIdenticalTextHasNoHunks() {
        XCTAssertEqual(TextMatching.diff(original: s("same text"), revised: s("same text")), [])
    }

    func testHeavyRewriteBecomesOneReplacement() {
        let hunks = TextMatching.diff(original: s("we believe it shows high use of the fleet"),
                                      revised: s("it falls below the fleet threshold"))
        XCTAssertEqual(hunks.count, 1)
    }
}

final class ClaudeCLITests: XCTestCase {
    let exe = URL(fileURLWithPath: "/usr/local/bin/claude")

    func testSubscriptionAllowed() {
        let c = ClaudeCLI.interpret(status: ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
                                             "subscriptionType": "max"], executable: exe)
        XCTAssertEqual(c, .subscription(executable: exe, plan: "max", email: nil))
        XCTAssertTrue(ClaudeCLI.interpret(status: ["loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"], executable: exe).isReady)
    }

    func testPayPerUseBlocked() {
        for status: [String: Any] in [
            ["loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty"],
            ["loggedIn": true, "authMethod": "api_key_helper", "apiProvider": "firstParty"],
            ["loggedIn": true, "authMethod": "third_party", "apiProvider": "bedrock"],
            ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "apiKeySource": "ANTHROPIC_API_KEY"],
        ] {
            XCTAssertFalse(ClaudeCLI.interpret(status: status, executable: exe).isReady, "\(status)")
        }
        XCTAssertEqual(ClaudeCLI.interpret(status: ["loggedIn": false, "authMethod": "none"], executable: exe), .signedOut(executable: exe))
    }

    func testEnvironmentDropsBillingVariables() {
        let cli = ClaudeCLI()
        setenv("ANTHROPIC_API_KEY", "sk-test", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        XCTAssertNil(cli.environment(for: exe)["ANTHROPIC_API_KEY"])
    }

    func testDecodesStructuredReply() throws {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"ok","edits":[],"comments":[{"paragraph":1,"quote":"q","comment":"c"}]}}"#
        let plan = try ClaudeCLI.decodeReply(.init(status: 0, stdout: Data(json.utf8), stderr: Data()))
        XCTAssertEqual(plan.comments.count, 1)
    }

    func testDecodesErrorReply() {
        let json = #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}"#
        XCTAssertThrowsError(try ClaudeCLI.decodeReply(.init(status: 1, stdout: Data(json.utf8), stderr: Data()))) { error in
            XCTAssertTrue(error.localizedDescription.contains("usage limit"))
        }
    }
}

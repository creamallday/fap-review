// Developer tool for exercising ReviewCore without the app (and on Linux).
//
//   review-tool text <doc.docx>
//   review-tool apply <doc.docx> <plan.json> <out.docx> [author]
//   review-tool status
//   review-tool review <doc.docx> <criteria.txt> [instructions] [--inherit-env]
import Foundation
import ReviewCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: review-tool text|apply|status|review …") }

func report(_ r: RedlineReport) {
    print("tracked changes: \(r.trackedChanges)  comments: \(r.comments)  skipped: \(r.skipped.count)")
    for s in r.skipped { print("  skipped \(s.kind.rawValue) P\(s.paragraph) “\(s.excerpt)”: \(s.reason)") }
}

do {
    switch command {
    case "text":
        guard args.count == 2 else { fail("usage: review-tool text <doc.docx>") }
        for p in try RedlineEngine.readText(of: URL(fileURLWithPath: args[1])).paragraphs {
            print("[P\(p.index)\(p.editable ? "" : " · read-only")] \(p.text)")
        }
    case "apply":
        guard args.count >= 4 else { fail("usage: review-tool apply <doc.docx> <plan.json> <out.docx> [author]") }
        let plan = try JSONDecoder().decode(ReviewPlan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let r = try RedlineEngine.apply(plan, to: URL(fileURLWithPath: args[1]), writingTo: URL(fileURLWithPath: args[3]),
                                        options: RedlineOptions(author: args.count > 4 ? args[4] : "Claude"))
        report(r)
    case "status":
        let cli = ClaudeCLI()
        cli.inheritEnvironment = args.contains("--inherit-env")
        print(await cli.connection())
    case "review":
        guard args.count >= 3 else { fail("usage: review-tool review <doc.docx> <criteria.txt> [instructions]") }
        let cli = ClaudeCLI()
        cli.inheritEnvironment = args.contains("--inherit-env")
        let rest = args.dropFirst(3).filter { $0 != "--inherit-env" }
        let profile = ReviewProfile(name: "Test", criteria: try String(contentsOfFile: args[2], encoding: .utf8))
        let outcome = try await ReviewPipeline.run(
            ReviewRequest(source: URL(fileURLWithPath: args[1]), profile: profile,
                          instructions: rest.first ?? "", author: "Claude"),
            provider: cli, progress: { print("…", $0) })
        print("saved:", outcome.output.path)
        print("summary:", outcome.summary)
        report(outcome.report)
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}

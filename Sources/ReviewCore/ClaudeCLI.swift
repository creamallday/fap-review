import Foundation

/// How Claude Code is set up on this Mac, as far as reviewing is concerned.
public enum ClaudeConnection: Equatable, Sendable {
    case notInstalled
    case signedOut(executable: URL)
    /// Signed in with a Claude subscription (Pro, Max, Team or Enterprise seat).
    case subscription(executable: URL, plan: String?, email: String?)
    /// Signed in, but requests would be billed outside the subscription. We refuse to run.
    case blocked(executable: URL, reason: String)
    case failed(String)

    public var isReady: Bool { if case .subscription = self { return true } else { return false } }
}

/// Runs the user's own Claude Code CLI in non-interactive mode. Using the CLI means the user's
/// existing Claude subscription sign-in is used, and nothing in this app holds credentials.
public final class ClaudeCLI: @unchecked Sendable {
    public var customPath: String?
    public var model: String?
    /// Only for development: keep the caller's environment (e.g. a proxy base URL) untouched.
    public var inheritEnvironment = false
    public var timeout: TimeInterval = 15 * 60

    public init(customPath: String? = nil, model: String? = nil) {
        self.customPath = customPath
        self.model = model
    }

    // MARK: Locating

    static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/Library/pnpm/claude",
        ]
    }()

    public func locate() -> URL? {
        let fm = FileManager.default
        if let customPath, !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for path in Self.candidatePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for dir in Self.searchPath.split(separator: ":") {
            let path = "\(dir)/claude"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Apps opened from Finder get a minimal PATH. Ask the login shell for the real one once,
    /// so an npm-installed `claude` can find `node`.
    static let searchPath: String = {
        var parts: [String] = []
        #if os(macOS)
        // Interactive login shell so PATH changes in .zprofile and .zshrc (nvm, Homebrew…) are seen.
        // A marker separates the value from anything the user's startup files print.
        let marker = "__FAP_PATH__"
        if let output = try? ProcessRunner.runSync(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-l", "-i", "-c", "printf '\(marker)%s' \"$PATH\""], timeout: 5),
           let range = output.range(of: marker, options: .backwards) {
            parts.append(String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #endif
        parts.append(ProcessInfo.processInfo.environment["PATH"] ?? "")
        var seen = Set<String>()
        return parts.joined(separator: ":").split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Environment for the child process. Variables that would route requests to pay-per-use
    /// API billing or a third-party provider are removed, so only the subscription sign-in applies.
    func environment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard !inheritEnvironment else { return env }
        let blocked: Set<String> = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
            "ANTHROPIC_VERTEX_PROJECT_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
        ]
        for key in env.keys where blocked.contains(key) { env[key] = nil }
        env["PATH"] = executable.deletingLastPathComponent().path + ":" + Self.searchPath
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: Status

    public func connection() async -> ClaudeConnection {
        guard let exe = locate() else { return .notInstalled }
        let result: ProcessRunner.Output
        do {
            result = try await ProcessRunner.run(executable: exe, arguments: ["auth", "status", "--json"],
                                                 environment: environment(for: exe), timeout: 30)
        } catch {
            return .failed("Couldn’t start Claude Code: \(error.localizedDescription)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return .blocked(executable: exe, reason: "This version of Claude Code is too old to confirm how it’s signed in. Update Claude Code, then check again.")
        }
        return Self.interpret(status: json, executable: exe)
    }

    static func interpret(status json: [String: Any], executable exe: URL) -> ClaudeConnection {
        let loggedIn = json["loggedIn"] as? Bool ?? false
        let method = json["authMethod"] as? String ?? "none"
        let provider = json["apiProvider"] as? String ?? "firstParty"
        guard loggedIn, method != "none" else { return .signedOut(executable: exe) }
        guard provider == "firstParty" else {
            return .blocked(executable: exe, reason: "Claude Code is set up to use a third-party provider (\(provider)), which is billed separately from your Claude subscription.")
        }
        if json["apiKeySource"] is String {
            return .blocked(executable: exe, reason: "Claude Code found an Anthropic API key, which is billed per use. Remove the API key so your Claude subscription is used.")
        }
        switch method {
        case "claude.ai", "oauth_token":
            return .subscription(executable: exe, plan: json["subscriptionType"] as? String, email: json["email"] as? String)
        case "api_key", "api_key_helper":
            return .blocked(executable: exe, reason: "Claude Code is signed in with an Anthropic Console API key, which is billed per use. Sign in with your Claude subscription instead.")
        default:
            return .blocked(executable: exe, reason: "Claude Code is signed in with a method that may be billed separately (\(method)). Sign in with your Claude subscription instead.")
        }
    }

    // MARK: Reviewing

    private var cachedHelp: String?

    private func supports(_ flag: String, executable: URL) async -> Bool {
        if cachedHelp == nil {
            let out = try? await ProcessRunner.run(executable: executable, arguments: ["--help"],
                                                   environment: environment(for: executable), timeout: 30)
            cachedHelp = out.map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
        }
        return cachedHelp!.contains(flag)
    }

    /// Sends one request and decodes the structured reply.
    public func requestPlan(system: String, prompt: String) async throws -> ReviewPlan {
        // Never call Claude unless the subscription check passes in this exact environment.
        let connection = await connection()
        guard case .subscription(let exe, _, _) = connection else {
            switch connection {
            case .notInstalled: throw ReviewError.claude("Claude Code isn’t installed.")
            case .signedOut: throw ReviewError.claude("Claude Code isn’t signed in.")
            case .blocked(_, let reason): throw ReviewError.claude(reason)
            case .failed(let m): throw ReviewError.claude(m)
            case .subscription: fatalError()
            }
        }

        var args = ["-p", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
                    "--system-prompt", system]
        if await supports("--tools", executable: exe) { args += ["--tools", ""] } else { args += ["--disallowedTools", "Bash,Edit,Write,Read,WebFetch,WebSearch,Glob,Grep,NotebookEdit,Task"] }
        if await supports("--safe-mode", executable: exe) { args.append("--safe-mode") }
        if await supports("--disable-slash-commands", executable: exe) { args.append("--disable-slash-commands") }
        let useSchema = await supports("--json-schema", executable: exe)
        var fullPrompt = prompt
        if useSchema {
            args += ["--json-schema", ReviewPlan.jsonSchema]
        } else {
            fullPrompt += "\n\nRespond with only a JSON object matching this JSON Schema:\n\(ReviewPlan.jsonSchema)"
        }
        if let model, !model.isEmpty { args += ["--model", model] }

        // Run in an empty private folder so no project settings or files are picked up.
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("fap-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let output = try await ProcessRunner.run(executable: exe, arguments: args, environment: environment(for: exe),
                                                 stdin: Data(fullPrompt.utf8), workingDirectory: workdir, timeout: timeout)
        return try Self.decodeReply(output)
    }

    static func decodeReply(_ output: ProcessRunner.Output) throws -> ReviewPlan {
        guard let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            let err = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let out = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReviewError.claude(friendly(err.isEmpty ? out : err))
        }
        let resultText = json["result"] as? String ?? ""
        if json["is_error"] as? Bool == true || (json["subtype"] as? String).map({ $0 != "success" }) == true {
            throw ReviewError.claude(friendly(resultText.isEmpty ? "Claude couldn’t complete the review." : resultText))
        }
        let decoder = JSONDecoder()
        if let structured = json["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let plan = try? decoder.decode(ReviewPlan.self, from: data) {
            return plan
        }
        if let start = resultText.firstIndex(of: "{"), let end = resultText.lastIndex(of: "}"),
           let plan = try? decoder.decode(ReviewPlan.self, from: Data(resultText[start...end].utf8)) {
            return plan
        }
        let snippet = String(resultText.prefix(300))
        throw ReviewError.claude("Claude’s reply couldn’t be understood. Please try again.\n\nDetails: exit status \(output.status)\(snippet.isEmpty ? "" : ", reply began: \(snippet)")")
    }

    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("limit reached") {
            return "You’ve reached your Claude usage limit for now. \(message)"
        }
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("invalid api key") {
            return "Claude Code isn’t signed in. Open Settings › Claude to sign in."
        }
        return message.isEmpty ? "Claude Code stopped unexpectedly." : message
    }
}

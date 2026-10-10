import AppKit
import Observation
import ReviewCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        case reviewing(ReviewStage)
        case finished(ReviewOutcome)
        case failed(String)
    }

    // MARK: Review state

    var document: URL?
    var instructions = ""
    var phase: Phase = .idle
    @ObservationIgnored private var reviewTask: Task<Void, Never>?

    var isReviewing: Bool { if case .reviewing = phase { return true } else { return false } }

    // MARK: Profiles (stored in Application Support)

    @ObservationIgnored private let store = ProfileStore()
    var profiles: [ReviewProfile] { didSet { try? store.save(profiles) } }
    var selectedProfileID: UUID? {
        didSet { defaults.set(selectedProfileID?.uuidString, forKey: Keys.profile) }
    }
    var selectedProfile: ReviewProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    // MARK: Preferences

    @ObservationIgnored private let defaults = UserDefaults.standard
    private enum Keys {
        static let profile = "selectedProfile", author = "reviewerName", model = "model"
        static let claudePath = "claudePath", outputFolder = "outputFolder"
    }
    var reviewerName: String { didSet { defaults.set(reviewerName, forKey: Keys.author) } }
    var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    var claudePath: String { didSet { defaults.set(claudePath, forKey: Keys.claudePath); Task { await refreshConnection() } } }
    /// Empty means "next to the original".
    var outputFolder: String { didSet { defaults.set(outputFolder, forKey: Keys.outputFolder) } }

    // MARK: Claude

    var connection: ClaudeConnection?
    var isCheckingConnection = false

    private init() {
        profiles = store.load()
        reviewerName = defaults.string(forKey: Keys.author) ?? "Claude"
        model = defaults.string(forKey: Keys.model) ?? ""
        claudePath = defaults.string(forKey: Keys.claudePath) ?? ""
        outputFolder = defaults.string(forKey: Keys.outputFolder) ?? ""
        selectedProfileID = defaults.string(forKey: Keys.profile).flatMap(UUID.init(uuidString:))
        if selectedProfile?.id != selectedProfileID { selectedProfileID = profiles.first?.id }
    }

    func refreshConnection() async {
        isCheckingConnection = true
        let cli = ClaudeCLI(customPath: claudePath.isEmpty ? nil : claudePath)
        connection = await cli.connection()
        isCheckingConnection = false
    }

    // MARK: Document

    static let wordType = UTType(filenameExtension: "docx") ?? .data

    @discardableResult
    func setDocument(_ url: URL) -> Bool {
        guard !isReviewing else { return false }
        guard url.pathExtension.lowercased() == "docx" else {
            phase = .failed("“\(url.lastPathComponent)” isn’t a Word document. Choose a .docx file.")
            return false
        }
        withAnimation(.spring(duration: 0.3)) {
            document = url
            phase = .idle
        }
        return true
    }

    var canReview: Bool {
        document != nil && selectedProfile != nil && !isReviewing && connection?.isReady == true
    }

    // MARK: Reviewing

    func startReview() {
        guard canReview, let document, let profile = selectedProfile else { return }
        let request = ReviewRequest(
            source: document, profile: profile, instructions: instructions, author: reviewerName,
            outputDirectory: outputFolder.isEmpty ? nil : URL(fileURLWithPath: outputFolder, isDirectory: true))
        let cli = ClaudeCLI(customPath: claudePath.isEmpty ? nil : claudePath, model: model.isEmpty ? nil : model)
        phase = .reviewing(.reading)

        reviewTask = Task { [weak self] in
            do {
                let outcome = try await ReviewPipeline.run(request, provider: cli) { stage in
                    Task { @MainActor in AppModel.shared.showStage(stage) }
                }
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.35)) { self?.phase = .finished(outcome) }
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                self?.phase = .idle
            } catch ReviewError.cancelled {
                self?.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation { self?.phase = .failed(error.localizedDescription) }
                Task { await self?.refreshConnection() }
            }
        }
    }

    private func showStage(_ stage: ReviewStage) {
        guard isReviewing else { return }
        withAnimation(.easeInOut(duration: 0.2)) { phase = .reviewing(stage) }
    }

    func cancelReview() {
        reviewTask?.cancel()
        reviewTask = nil
        withAnimation { phase = .idle }
    }

    /// Back to the start, ready for the next document.
    func reset() {
        withAnimation(.spring(duration: 0.35)) {
            document = nil
            instructions = ""
            phase = .idle
        }
    }

    func dismissError() {
        withAnimation { phase = .idle }
    }

    // MARK: Results

    static var wordURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") }

    func openInWord(_ url: URL) {
        if let word = Self.wordURL {
            NSWorkspace.shared.open([url], withApplicationAt: word, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Profiles

    func addProfile() -> ReviewProfile {
        let profile = ReviewProfile(name: "New Profile", criteria: "")
        profiles.append(profile)
        return profile
    }

    func duplicate(_ profile: ReviewProfile) -> ReviewProfile {
        let copy = ReviewProfile(name: profile.name + " Copy", criteria: profile.criteria)
        profiles.append(copy)
        return copy
    }

    func delete(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
    }

    // MARK: One-time setup

    /// Opens Terminal with a short script for the one-time Claude Code install or sign-in.
    /// Everyday reviewing never needs Terminal.
    func runSetup(install: Bool) {
        var lines = ["#!/bin/zsh", "clear"]
        if install {
            lines += [
                "echo 'Installing Claude Code (official installer from claude.ai)…'",
                "curl -fsSL https://claude.ai/install.sh | bash || exit 1",
                "export PATH=\"$HOME/.local/bin:$PATH\"",
            ]
        }
        let exe: String
        if case .signedOut(let url)? = connection { exe = "'\(url.path)'" }
        else if case .blocked(let url, _)? = connection { exe = "'\(url.path)'" }
        else { exe = "claude" }
        if case .blocked? = connection { lines.append("\(exe) auth logout") }
        lines += [
            "echo ''",
            "echo 'Sign in with your Claude subscription account in the browser window that opens.'",
            "\(exe) auth login --claudeai",
            "echo ''",
            "echo 'All set. You can close this window and return to FAP Memo Reviewer.'",
        ]
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("FAP Memo Reviewer Setup.command")
        do {
            try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            phase = .failed("Couldn’t start setup: \(error.localizedDescription)")
        }
    }
}

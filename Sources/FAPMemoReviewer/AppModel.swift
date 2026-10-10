import AppKit
import Observation
import ReviewCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct BatchProgress: Equatable {
        var stage: ReviewStage
        var index: Int
        var total: Int
        var name: String
    }

    struct ItemFailure: Error {
        var message: String
        var details: String
    }

    struct BatchItem: Identifiable {
        let id = UUID()
        let source: URL
        let result: Result<ReviewOutcome, ItemFailure>
    }

    enum Phase {
        case idle
        case reviewing(BatchProgress)
        case finished([BatchItem])
        case failed(String)
    }

    static let maxDocuments = 25

    // MARK: Review state

    var documents: [URL] = []
    /// Brief note about files that couldn't be added.
    var notice: String?
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
    static let defaultReviewerName = "Chris Holm"
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
        // "Claude" was the earlier default; treat it as unset so the new default applies.
        let storedName = defaults.string(forKey: Keys.author)
        reviewerName = (storedName == nil || storedName == "Claude") ? Self.defaultReviewerName : storedName!
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

    /// Adds Word documents to the list. Anything else is skipped with a notice.
    @discardableResult
    func addDocuments(_ urls: [URL]) -> Bool {
        guard !isReviewing else { return false }
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        // New files after finished results start a fresh batch.
        var list = documents
        if case .finished = phase { list = [] }
        var skipped = 0, added = 0
        for url in files {
            guard url.pathExtension.lowercased() == "docx", !url.lastPathComponent.hasPrefix("~$") else { skipped += 1; continue }
            guard !list.contains(url) else { continue }
            guard list.count < Self.maxDocuments else { skipped += 1; continue }
            list.append(url)
            added += 1
        }
        withAnimation(.spring(duration: 0.3)) {
            documents = list
            phase = .idle
            notice = skipped == 0 ? nil
                : "\(skipped) file\(skipped == 1 ? " was" : "s were") skipped. Only Word documents (.docx) can be reviewed, up to \(Self.maxDocuments) at a time."
        }
        return added > 0 || (skipped == 0 && !files.isEmpty)
    }

    func removeDocument(_ url: URL) {
        withAnimation(.spring(duration: 0.3)) {
            documents.removeAll { $0 == url }
            notice = nil
        }
    }

    func clearDocuments() {
        withAnimation(.spring(duration: 0.3)) { documents = []; notice = nil }
    }

    var canReview: Bool {
        !documents.isEmpty && selectedProfile != nil && !isReviewing && connection?.isReady == true
    }

    // MARK: Reviewing

    func startReview() {
        guard canReview, let profile = selectedProfile else { return }
        let sources = documents
        let folder = outputFolder.isEmpty ? nil : URL(fileURLWithPath: outputFolder, isDirectory: true)
        let instructions = instructions, author = reviewerName
        let cli = ClaudeCLI(customPath: claudePath.isEmpty ? nil : claudePath, model: model.isEmpty ? nil : model)
        notice = nil
        phase = .reviewing(BatchProgress(stage: .reading, index: 1, total: sources.count, name: sources[0].lastPathComponent))

        reviewTask = Task { [weak self] in
            var items: [BatchItem] = []
            var stopReason: String?
            for (i, source) in sources.enumerated() {
                if Task.isCancelled { return }
                if let stopReason {
                    items.append(BatchItem(source: source, result: .failure(ItemFailure(message: stopReason, details: "Not reviewed."))))
                    continue
                }
                let request = ReviewRequest(source: source, profile: profile, instructions: instructions,
                                            author: author, outputDirectory: folder)
                let name = source.lastPathComponent
                await MainActor.run {
                    self?.showStage(BatchProgress(stage: .reading, index: i + 1, total: sources.count, name: name))
                }
                do {
                    let outcome = try await ReviewPipeline.run(request, provider: cli) { stage in
                        Task { @MainActor in
                            AppModel.shared.showStage(BatchProgress(stage: stage, index: i + 1, total: sources.count, name: name))
                        }
                    }
                    items.append(BatchItem(source: source, result: .success(outcome)))
                } catch is CancellationError {
                    return
                } catch ReviewError.cancelled {
                    return
                } catch {
                    if Task.isCancelled { return }
                    items.append(BatchItem(source: source, result: .failure(
                        ItemFailure(message: error.localizedDescription, details: String(describing: error)))))
                    // A problem with Claude itself (limit reached, signed out) would repeat for every file.
                    if case ReviewError.claude = error {
                        stopReason = "Not reviewed because Claude stopped responding on an earlier document."
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let finished = items
            await MainActor.run {
                withAnimation(.spring(duration: 0.35)) { self?.phase = .finished(finished) }
                if finished.contains(where: { if case .success = $0.result { return true } else { return false } }) {
                    NSSound(named: "Glass")?.play()
                }
            }
            if finished.contains(where: { if case .failure = $0.result { return true } else { return false } }) {
                await self?.refreshConnection()
            }
        }
    }

    private func showStage(_ progress: BatchProgress) {
        guard isReviewing else { return }
        withAnimation(.easeInOut(duration: 0.2)) { phase = .reviewing(progress) }
    }

    /// Reviews again only the documents that failed.
    func retryFailed(_ items: [BatchItem]) {
        let failed = items.compactMap { item -> URL? in if case .failure = item.result { return item.source } else { return nil } }
        guard !failed.isEmpty else { return }
        documents = failed
        phase = .idle
        startReview()
    }

    func cancelReview() {
        reviewTask?.cancel()
        reviewTask = nil
        withAnimation { phase = .idle }
    }

    /// Back to the start, ready for the next document.
    func reset() {
        withAnimation(.spring(duration: 0.35)) {
            documents = []
            notice = nil
            instructions = ""
            phase = .idle
        }
    }

    func dismissError() {
        withAnimation { phase = .idle }
    }

    // MARK: Results

    static var wordURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") }

    func openInWord(_ urls: [URL]) {
        if let word = Self.wordURL {
            NSWorkspace.shared.open(urls, withApplicationAt: word, configuration: NSWorkspace.OpenConfiguration())
        } else {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    func openInWord(_ url: URL) { openInWord([url]) }

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

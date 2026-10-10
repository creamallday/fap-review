import AppKit
import Combine
import ReviewCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let connection = model.connection, !connection.isReady {
                SetupBanner(connection: connection)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch model.phase {
                case .idle:
                    ComposeView()
                case .reviewing(let progress):
                    ProgressPanel(progress: progress)
                case .finished(let items):
                    ResultsPanel(items: items)
                case .failed(let message):
                    ErrorPanel(message: message)
                }
            }
            .padding(24)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: model.connection?.isReady)
        .task { await model.refreshConnection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up a sign-in finished in Terminal without a restart.
            if model.connection?.isReady != true { Task { await model.refreshConnection() } }
        }
    }
}

// MARK: - Compose

private struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @FocusState private var instructionsFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            DropZone()

            VStack(alignment: .leading, spacing: 8) {
                Text("Review Profile").font(.headline)
                HStack(spacing: 8) {
                    Picker("Review Profile", selection: $model.selectedProfileID) {
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Edit review profiles")
                    .accessibilityLabel("Edit review profiles")
                }
                if let count = model.selectedProfile?.documents.count, count > 0 {
                    Text("Includes \(count) criteria document\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Instructions").font(.headline)
                    Text("Optional").font(.subheadline).foregroundStyle(.secondary)
                }
                TextEditor(text: $model.instructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($instructionsFocused)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                    .frame(height: 76)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(instructionsFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                                          lineWidth: instructionsFocused ? 2 : 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if model.instructions.isEmpty {
                            Text("Anything specific for this memo, e.g. “Focus on the utilization data.”")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Instructions")
            }

            HStack {
                if model.connection == nil || model.isCheckingConnection {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Claude…").font(.callout).foregroundStyle(.secondary)
                } else if case .subscription(_, let plan, _)? = model.connection {
                    Label(planLabel(plan), systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Button {
                    model.startReview()
                } label: {
                    Text(model.documents.count > 1 ? "Review \(model.documents.count) Documents" : "Review").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canReview)
                .help(model.documents.isEmpty ? "Add a Word document first" : "Review with Claude (⌘↩)")
            }
        }
    }

    private func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "Using your Claude subscription" }
        return "Using your Claude \(plan.prefix(1).uppercased() + plan.dropFirst()) plan"
    }
}

// MARK: - Progress

private struct ProgressPanel: View {
    @Environment(AppModel.self) private var model
    let progress: AppModel.BatchProgress

    private var title: String {
        switch progress.stage {
        case .reading: return "Reading the document…"
        case .reviewing: return "Claude is reviewing…"
        case .refining: return "Double-checking suggestions…"
        case .writing: return "Adding tracked changes and comments…"
        }
    }

    private var detail: String {
        if progress.total > 1 { return "Document \(progress.index) of \(progress.total)" }
        switch progress.stage {
        case .reviewing, .refining: return "This usually takes under a minute."
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(progress.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if progress.total > 1 {
                ProgressView(value: Double(progress.index - 1), total: Double(progress.total))
                    .frame(maxWidth: 280)
            } else {
                ProgressView().controlSize(.large).padding(.top, 6)
            }
            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.medium)).contentTransition(.opacity)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Button("Cancel") { model.cancelReview() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Results

private struct ResultsPanel: View {
    @Environment(AppModel.self) private var model
    let items: [AppModel.BatchItem]

    var body: some View {
        if items.count == 1 {
            switch items[0].result {
            case .success(let outcome): SingleResult(outcome: outcome)
            case .failure(let failure): ErrorPanel(message: failure.message, details: failure.details, retry: items)
            }
        } else {
            BatchResult(items: items)
        }
    }
}

private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

private struct BatchResult: View {
    @Environment(AppModel.self) private var model
    let items: [AppModel.BatchItem]

    private var outcomes: [ReviewOutcome] { items.compactMap { if case .success(let o) = $0.result { return o } else { return nil } } }
    private var failures: Int { items.count - outcomes.count }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: failures == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 42))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, failures == 0 ? Color.green : Color.orange)
                Text(failures == 0 ? "Reviews Complete" : "Some Reviews Didn’t Finish").font(.title2.weight(.semibold))
                Text("\(outcomes.count) of \(items.count) reviewed" + (failures > 0 ? " · \(failures) failed" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Review More") { model.reset() }.controlSize(.large)
                if failures > 0 {
                    Button("Retry Failed") { model.retryFailed(items) }.controlSize(.large)
                }
                Spacer()
                if !outcomes.isEmpty {
                    Button {
                        model.openInWord(outcomes.map(\.output))
                    } label: {
                        Text(AppModel.wordURL == nil ? "Open All" : "Open All in Word").frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: AppModel.BatchItem) -> some View {
        switch item.result {
        case .success(let outcome):
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: outcome.output.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.output.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("\(count(outcome.report.trackedChanges, "tracked change")) · \(count(outcome.report.comments, "comment"))"
                         + (outcome.report.skipped.isEmpty ? "" : " · \(outcome.report.skipped.count) left out"))
                        .font(.caption)
                        .foregroundStyle(outcome.report.skipped.isEmpty ? Color.secondary : Color.orange)
                }
                Spacer()
                Button("Show") { model.showInFinder(outcome.output) }.controlSize(.small)
                Button("Open") { model.openInWord(outcome.output) }.controlSize(.small)
            }
            .padding(10)
        case .failure(let failure):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(failure.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
    }
}

private struct SingleResult: View {
    @Environment(AppModel.self) private var model
    let outcome: ReviewOutcome
    @State private var showSkipped = false

    var body: some View {
        let report = outcome.report
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .symbolEffect(.bounce, value: outcome.output)
                Text("Review Complete").font(.title2.weight(.semibold))
                Text("\(count(report.trackedChanges, "tracked change")) · \(count(report.comments, "comment"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !outcome.summary.isEmpty {
                ScrollView {
                    Text(outcome.summary)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            if !report.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation { showSkipped.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("\(count(report.skipped.count, "suggestion")) couldn’t be placed reliably and \(report.skipped.count == 1 ? "was" : "were") left out")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showSkipped ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSkipped {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(report.skipped) { item in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("“\(item.excerpt)”").font(.callout.weight(.medium)).lineLimit(2)
                                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: outcome.output.path))
                    .resizable().frame(width: 18, height: 18)
                Text(outcome.output.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("in \(outcome.output.deletingLastPathComponent().lastPathComponent)")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)

            HStack {
                Button("Review Another") { model.reset() }
                    .controlSize(.large)
                Spacer()
                Button("Show in Finder") { model.showInFinder(outcome.output) }
                    .controlSize(.large)
                Button {
                    model.openInWord(outcome.output)
                } label: {
                    Text(AppModel.wordURL == nil ? "Open Document" : "Open in Word").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Error

private struct ErrorPanel: View {
    @Environment(AppModel.self) private var model
    let message: String
    var details: String?
    var retry: [AppModel.BatchItem]?
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("The Review Didn’t Finish").font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("No reviewed copy was saved, and your original document is unchanged.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            if let details, !details.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showDetails) {
                    VStack(alignment: .trailing, spacing: 6) {
                        ScrollView {
                            Text(details)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message + "\n\n" + details, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                .font(.callout)
            }
            HStack {
                Button("Start Over") { model.reset() }.controlSize(.large)
                Button("Try Again") {
                    if let retry { model.retryFailed(retry) } else { model.dismissError(); model.startReview() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(retry == nil && model.documents.isEmpty)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
    }
}

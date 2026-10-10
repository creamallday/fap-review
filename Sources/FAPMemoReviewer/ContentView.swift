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
                case .reviewing(let stage):
                    ProgressPanel(stage: stage)
                case .finished(let outcome):
                    ResultPanel(outcome: outcome)
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
                    Text("Review").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canReview)
                .help(model.document == nil ? "Add a Word document first" : "Review with Claude (⌘↩)")
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
    let stage: ReviewStage

    private var title: String {
        switch stage {
        case .reading: return "Reading the document…"
        case .reviewing: return "Claude is reviewing…"
        case .refining: return "Double-checking suggestions…"
        case .writing: return "Adding tracked changes and comments…"
        }
    }

    private var detail: String {
        switch stage {
        case .reviewing, .refining: return "This usually takes under a minute."
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            if let document = model.document {
                DocumentBadge(url: document)
            }
            ProgressView()
                .controlSize(.large)
                .padding(.top, 6)
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

// MARK: - Result

private struct ResultPanel: View {
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

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

// MARK: - Error

private struct ErrorPanel: View {
    @Environment(AppModel.self) private var model
    let message: String

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
            HStack {
                Button("Start Over") { model.reset() }.controlSize(.large)
                Button("Try Again") {
                    model.dismissError()
                    model.startReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.document == nil)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
    }
}

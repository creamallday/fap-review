import ReviewCore
import SwiftUI

/// Shown above the window content when Claude Code needs a one-time setup step.
struct SetupBanner: View {
    @Environment(AppModel.self) private var model
    let connection: ClaudeConnection

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let action {
                        Button(action.0) { action.1() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Check Again") { Task { await model.refreshConnection() } }
                        .disabled(model.isCheckingConnection)
                    if model.isCheckingConnection { ProgressView().controlSize(.small) }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.orange.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var icon: String {
        if case .blocked = connection { return "creditcard.trianglebadge.exclamationmark" }
        return "person.crop.circle.badge.exclamationmark"
    }

    private var title: String {
        switch connection {
        case .notInstalled: return "Set up Claude to start reviewing"
        case .signedOut: return "Sign in to Claude"
        case .blocked: return "Reviewing is paused to avoid API charges"
        case .failed: return "Claude isn’t available"
        case .subscription: return ""
        }
    }

    private var message: String {
        switch connection {
        case .notInstalled:
            return "FAP Memo Reviewer uses Claude Code, Anthropic’s official app, so reviews run on your existing Claude subscription. Installing it takes about a minute and only happens once."
        case .signedOut:
            return "Claude Code is installed but not signed in. Sign in once with your Claude subscription account."
        case .blocked(_, let reason):
            return reason + " Reviews only run on a Claude subscription, so nothing is billed per use."
        case .failed(let message):
            return message
        case .subscription:
            return ""
        }
    }

    private var action: (String, @MainActor () -> Void)? {
        switch connection {
        case .notInstalled: return ("Install Claude Code…", { model.runSetup(install: true) })
        case .signedOut: return ("Sign In…", { model.runSetup(install: false) })
        case .blocked: return ("Sign In with Subscription…", { model.runSetup(install: false) })
        default: return nil
        }
    }
}

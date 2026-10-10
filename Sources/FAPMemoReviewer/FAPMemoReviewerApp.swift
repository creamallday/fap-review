import AppKit
import SwiftUI

@main
struct FAPMemoReviewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("FAP Memo Reviewer", id: "main") {
            ContentView()
                .environment(model)
                .frame(width: 540)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Documents…") { NotificationCenter.default.post(name: .chooseDocument, object: nil) }
                    .keyboardShortcut("o")
                    .disabled(model.isReviewing)
            }
            CommandMenu("Review") {
                Button("Review Document") { model.startReview() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canReview)
                Button("Cancel Review") { model.cancelReview() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isReviewing)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

extension Notification.Name {
    static let chooseDocument = Notification.Name("chooseDocument")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder "Open With" and drops onto the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.addDocuments(urls) }
    }
}

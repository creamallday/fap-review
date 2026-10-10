import AppKit
import ReviewCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "list.bullet.rectangle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 620)
    }
}

// MARK: - Profiles

private struct ProfilesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name.isEmpty ? "Untitled" : profile.name).tag(profile.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 0) {
                    Button { selection = model.addProfile().id } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                        .help("New profile")
                    Divider().frame(height: 16)
                    Button {
                        if let id = selection { model.delete(id); selection = model.profiles.first?.id }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .disabled(selection == nil || model.profiles.count < 2)
                        .help("Delete profile")
                    Divider().frame(height: 16)
                    Button {
                        if let p = model.profiles.first(where: { $0.id == selection }) { selection = model.duplicate(p).id }
                    } label: { Image(systemName: "plus.square.on.square").frame(width: 24, height: 22) }
                        .disabled(selection == nil)
                        .help("Duplicate profile")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .top) { Divider() }
            }
            .frame(width: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))

            Group {
                if let index = model.profiles.firstIndex(where: { $0.id == selection }) {
                    ProfileEditor(profile: Bindable(model).profiles[index])
                } else {
                    Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, 20)
        }
        .padding(20)
        .frame(height: 580)
        .onAppear { selection = selection ?? model.selectedProfile?.id }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: ReviewProfile
    @State private var isImporting = false
    @State private var isTargeted = false
    @State private var importError: String?

    private func add(_ urls: [URL]) {
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                profile.documents.append(try CriteriaImporter.document(from: url))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        importError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Criteria Documents").font(.headline)
                Spacer()
                Button("Add Files…") { isImporting = true }
            }
            Text("Upload policy excerpts or checklists (.docx, .pdf, .txt, .md). Their text is added to every review that uses this profile. Replace a file by removing it and adding the newer version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                if profile.documents.isEmpty {
                    Text("Drop files here")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(profile.documents) { doc in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.name).lineLimit(1).truncationMode(.middle)
                                Text("\(doc.text.count.formatted()) characters · added \(doc.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                profile.documents.removeAll { $0.id == doc.id }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .help("Remove “\(doc.name)”")
                                .accessibilityLabel("Remove \(doc.name)")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        if doc.id != profile.documents.last?.id { Divider() }
                    }
                }
            }
            .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(0.12)))
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                add(files)
                return !files.isEmpty
            } isTargeted: { isTargeted = $0 }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: CriteriaImporter.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.headline)
                TextField("Profile name", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Screening Criteria").font(.headline)
                Text("What Claude should check every memo against. Plain language works best.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $profile.criteria)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            }
            documentsSection
            Text("Saved automatically on this Mac only.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Name on tracked changes", text: $model.reviewerName, prompt: Text(AppModel.defaultReviewerName))
            } footer: {
                Text("Shown as the author of each tracked change and comment in Word.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Save reviewed copies", selection: Binding(
                    get: { model.outputFolder.isEmpty ? 0 : 1 },
                    set: { choice in
                        if choice == 0 { model.outputFolder = "" } else { chooseFolder() }
                    })) {
                    Text("Next to the original").tag(0)
                    Text(model.outputFolder.isEmpty ? "In a folder…" : (model.outputFolder as NSString).lastPathComponent).tag(1)
                }
                if !model.outputFolder.isEmpty {
                    LabeledContent("Folder") {
                        HStack {
                            Text((model.outputFolder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Change…") { chooseFolder() }
                        }
                    }
                }
            } footer: {
                Text("The original document is never modified. Each review is saved as a new copy named “… (Reviewed).docx”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.outputFolder = url.path }
    }
}

// MARK: - Claude

private struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if model.isCheckingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                        }
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    if model.connection?.isReady == false {
                        Button(model.connection == .notInstalled ? "Install Claude Code…" : "Sign In…") {
                            model.runSetup(install: model.connection == .notInstalled)
                        }
                    }
                    Button("Check Again") { Task { await model.refreshConnection() } }
                        .disabled(model.isCheckingConnection)
                }
            } footer: {
                Text("Reviews run through Claude Code, Anthropic’s official app, using your Claude subscription. If Claude Code is set up with an API key or another paid provider, reviewing is paused instead of creating charges. Your document text is sent to Claude only when you click Review.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Model", selection: $model.model) {
                    Text("Default").tag("")
                    Text("Opus").tag("opus")
                    Text("Sonnet").tag("sonnet")
                }
            } footer: {
                Text("Default uses Claude Code’s own choice for your plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    LabeledContent("Claude Code location") {
                        HStack {
                            TextField("", text: $model.claudePath, prompt: Text("Found automatically"))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseExecutable() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
        .task { if model.connection == nil { await model.refreshConnection() } }
    }

    private var statusColor: Color {
        switch model.connection {
        case .subscription?: return .green
        case nil: return .secondary
        default: return .orange
        }
    }

    private var statusText: String {
        switch model.connection {
        case nil: return "Checking…"
        case .notInstalled?: return "Claude Code isn’t installed"
        case .signedOut?: return "Not signed in"
        case .subscription(_, let plan, let email)?:
            var s = "Signed in with your Claude subscription"
            if let plan, !plan.isEmpty { s = "Signed in · Claude \(plan.prefix(1).uppercased() + plan.dropFirst())" }
            if let email, !email.isEmpty { s += " (\(email))" }
            return s
        case .blocked?: return "Paused: not using a subscription"
        case .failed(let m)?: return m
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.claudePath = url.path }
    }
}

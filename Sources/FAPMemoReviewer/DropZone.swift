import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The large target for a Word document: drop a file on it, or click to choose one.
struct DropZone: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(model.document == nil ? 0.18 : 0.10),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.25, dash: model.document == nil ? [6, 4] : []))

            if let document = model.document {
                HStack(spacing: 14) {
                    DocumentBadge(url: document, large: true)
                    Spacer(minLength: 0)
                    Button("Replace…") { isImporting = true }
                    Button {
                        withAnimation(.spring(duration: 0.3)) { model.document = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove document")
                    .accessibilityLabel("Remove document")
                }
                .padding(.horizontal, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                        .symbolEffect(.bounce, value: isTargeted)
                    Text("Drop a Word document here")
                        .font(.title3.weight(.medium))
                    Text("or click to choose a .docx file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(height: model.document == nil ? 170 : 92)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if model.document == nil { isImporting = true } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            return model.setDocument(url)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [AppModel.wordType]) { result in
            if case .success(let url) = result { model.setDocument(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseDocument)) { _ in isImporting = true }
        .animation(.spring(duration: 0.3), value: model.document)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.document == nil ? "Document drop zone. Click to choose a Word document." : "Selected document")
        .accessibilityAddTraits(model.document == nil ? .isButton : [])
    }
}

/// File icon, name and size.
struct DocumentBadge: View {
    let url: URL
    var large = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: large ? 52 : 40, height: large ? 52 : 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(large ? .headline : .body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var parts: [String] = []
        if let size = values?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = values?.contentModificationDate { parts.append("Modified \(date.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}

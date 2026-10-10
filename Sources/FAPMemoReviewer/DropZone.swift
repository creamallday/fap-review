import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The large target for Word documents: drop files on it, or click to choose them.
struct DropZone: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var isImporting = false

    private var isEmpty: Bool { model.documents.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(isEmpty ? 0.18 : 0.10),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.25, dash: isEmpty ? [6, 4] : []))

                if isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                        Text("Drop Word documents here")
                            .font(.title3.weight(.medium))
                        Text("or click to choose one or more .docx files")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.documents, id: \.self) { url in
                                HStack(spacing: 8) {
                                    DocumentBadge(url: url, large: model.documents.count == 1)
                                    Spacer(minLength: 0)
                                    Button {
                                        model.removeDocument(url)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove “\(url.lastPathComponent)”")
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, model.documents.count == 1 ? 20 : 8)
                                if url != model.documents.last { Divider().padding(.leading, 16) }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                }
            }
            .frame(minHeight: isEmpty ? 170 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { if isEmpty { isImporting = true } }

            if !isEmpty {
                HStack {
                    Button("Add More…") { isImporting = true }
                    if model.documents.count > 1 {
                        Button("Clear All") { model.clearDocuments() }
                    }
                    Spacer()
                    Text("\(model.documents.count) document\(model.documents.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addDocuments(urls)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [AppModel.wordType], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addDocuments(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseDocument)) { _ in isImporting = true }
        .animation(.spring(duration: 0.3), value: model.documents)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isEmpty ? "Document drop zone. Click to choose Word documents." : "Selected documents")
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

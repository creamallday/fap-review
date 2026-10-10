import Foundation
import ZIPFoundation

/// Read access to the parts of a .docx, plus writing a modified copy.
/// The source file is only ever opened for reading.
final class DocxPackage {
    let url: URL
    private let archive: Archive
    /// Entry paths in their original order.
    let entryPaths: [String]

    static let maxPartSize = 256 * 1024 * 1024

    init(url: URL) throws {
        self.url = url
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ReviewError.unreadableDocument("it isn’t a valid Word (.docx) file.")
        }
        entryPaths = archive.map(\.path)
        guard entryPaths.contains("[Content_Types].xml") else {
            throw ReviewError.unreadableDocument("it isn’t a valid Word (.docx) file.")
        }
    }

    func has(_ path: String) -> Bool { archive[path] != nil }

    func data(_ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw ReviewError.unreadableDocument("the part \(path) is missing.")
        }
        guard entry.uncompressedSize <= Self.maxPartSize else {
            throw ReviewError.unsupportedDocument("the part \(path) is unreasonably large.")
        }
        var out = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: false) { out.append($0) }
        } catch {
            throw ReviewError.unreadableDocument("the part \(path) is damaged.")
        }
        return out
    }

    /// Path of the main document part, resolved through the package relationships.
    func mainDocumentPath() throws -> String {
        let rels = try parseXML(try data("_rels/.rels"), part: "_rels/.rels")
        for rel in rels.rootElement()?.elementChildren ?? [] where localName(rel) == "Relationship" {
            if rel.attr("Type") == OOXML.officeDocumentRel, let target = rel.attr("Target") {
                return target.hasPrefix("/") ? String(target.dropFirst()) : target
            }
        }
        throw ReviewError.unreadableDocument("it has no main document part.")
    }

    /// Writes a copy of this package to `destination`, replacing the parts in `replacements`
    /// and appending `additions`. Every other part is copied with identical bytes.
    func writeCopy(to destination: URL, replacements: [String: Data], additions: [(String, Data)]) throws {
        let out: Archive
        do {
            out = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ReviewError.outputLocation("Couldn’t create the reviewed file at \(destination.path).")
        }
        func add(_ path: String, _ data: Data, date: Date) throws {
            try out.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             modificationDate: date, compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        for entry in archive {
            let date = entry.fileAttributes[.modificationDate] as? Date ?? Date()
            if entry.type == .directory {
                try out.addEntry(with: entry.path, type: .directory, uncompressedSize: Int64(0),
                                 modificationDate: date, provider: { _, _ in Data() })
                continue
            }
            guard entry.type == .file else { continue } // drop symlinks: Word never writes them
            let content = try replacements[entry.path] ?? data(entry.path)
            try add(entry.path, content, date: date)
        }
        for (path, content) in additions where archive[path] == nil {
            try add(path, content, date: Date())
        }
    }
}

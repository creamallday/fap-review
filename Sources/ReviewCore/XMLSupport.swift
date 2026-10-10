import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum OOXML {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let mathNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/math"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeDocumentRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let commentsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    static let commentsContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
    static let mainContentTypes: Set<String> = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml",
    ]
}

/// Parse options shared by every part we read, so text and whitespace survive a round trip.
let xmlParseOptions: XMLNode.Options = [
    .nodePreserveWhitespace,
    .nodePreserveEmptyElements,
    .nodePreserveAttributeOrder,
    .nodePreserveNamespaceOrder,
    .nodePreserveQuotes,
]

func parseXML(_ data: Data, part: String) throws -> XMLDocument {
    // Word never emits a DTD. Refusing one rules out entity expansion tricks in untrusted files.
    if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
        throw ReviewError.unsupportedDocument("\(part) contains a DTD, which Word documents never do.")
    }
    do {
        return try XMLDocument(data: data, options: xmlParseOptions)
    } catch {
        throw ReviewError.unsupportedDocument("\(part) is not valid XML (\(error.localizedDescription)).")
    }
}

func serializeXML(_ doc: XMLDocument, originalData: Data?) -> Data {
    doc.characterEncoding = "UTF-8"
    if let originalData, let head = String(data: originalData.prefix(200), encoding: .utf8),
       head.contains("standalone=\"yes\"") || head.contains("standalone='yes'") {
        doc.isStandalone = true
    }
    // Note: passing .nodePreserveWhitespace here makes swift-corelibs re-indent the output.
    return doc.xmlData(options: [.nodeCompactEmptyElement])
}

/// Deep copy built from qualified names. `copy()` on Linux re-declares namespaces on the copy.
func cloneElement(_ e: XMLElement) -> XMLElement {
    let c = XMLElement(name: e.name ?? "")
    for a in e.attributes ?? [] { c.setAttr(a.name ?? "", a.stringValue ?? "") }
    for child in e.children ?? [] {
        if let ce = child as? XMLElement {
            c.addChild(cloneElement(ce))
        } else if child.kind == .text, let text = XMLNode.text(withStringValue: child.stringValue ?? "") as? XMLNode {
            c.addChild(text)
        }
    }
    return c
}

extension XMLNode {
    var elementChildren: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }
}

extension XMLElement {
    /// Attribute lookup by qualified name ("w:id"). Iterating avoids platform differences in
    /// how `attribute(forName:)` treats prefixes.
    func attr(_ qualifiedName: String) -> String? {
        for node in attributes ?? [] where node.name == qualifiedName {
            return node.stringValue
        }
        return nil
    }

    func setAttr(_ qualifiedName: String, _ value: String) {
        if let existing = (attributes ?? []).first(where: { $0.name == qualifiedName }) {
            existing.stringValue = value
        } else if let node = XMLNode.attribute(withName: qualifiedName, stringValue: value) as? XMLNode {
            addAttribute(node)
        }
    }

    func insertSibling(_ node: XMLNode, before: Bool) {
        guard let parent = parent as? XMLElement else { return }
        let i = index + (before ? 0 : 1)
        parent.insertChild(node, at: i)
    }
}

/// Element names for a part, honouring whatever prefix the document binds to the
/// WordprocessingML namespace (almost always "w", but not guaranteed).
struct WordNames {
    let prefix: String

    init(root: XMLElement?) {
        var found = "w"
        for ns in root?.namespaces ?? [] where ns.stringValue == OOXML.wordNamespace {
            found = ns.name ?? "w"
            break
        }
        prefix = found
    }

    init(prefix: String) { self.prefix = prefix }

    func q(_ local: String) -> String { prefix.isEmpty ? local : "\(prefix):\(local)" }

    func local(_ element: XMLElement) -> String? {
        guard let name = element.name else { return nil }
        if prefix.isEmpty { return name.contains(":") ? nil : name }
        let p = prefix + ":"
        return name.hasPrefix(p) ? String(name.dropFirst(p.count)) : nil
    }

    func element(_ local: String, attributes: [(String, String)] = []) -> XMLElement {
        let e = XMLElement(name: q(local))
        for (k, v) in attributes { e.setAttr(k.contains(":") ? k : q(k), v) }
        return e
    }

    func textElement(_ local: String, _ text: String) -> XMLElement {
        let e = XMLElement(name: q(local))
        e.setAttr("xml:space", "preserve")
        e.stringValue = text
        return e
    }
}

/// Prefix-agnostic local name ("w:p" → "p", "m:oMath" → "oMath").
func localName(_ element: XMLElement) -> String {
    let name = element.name ?? ""
    if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
    return name
}

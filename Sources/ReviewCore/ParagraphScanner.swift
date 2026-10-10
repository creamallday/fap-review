import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A stretch of visible paragraph text backed by one inline element.
struct Piece {
    /// The `w:r` (or other inline element such as `m:oMath`) that renders this text.
    let node: XMLElement
    let start: Int
    let length: Int
    /// True when the text sits in a plain run that can be split, deleted and inserted next to
    /// without disturbing fields, existing revisions, content controls or embedded objects.
    let editable: Bool
    /// The text is the displayed result of a complex field (between its separate and end marks).
    var inFieldResult = false
    var end: Int { start + length }
}

/// The visible text of one `w:p`, as unicode scalars, mapped back to the XML that holds it.
final class ParagraphModel {
    let element: XMLElement
    let index: Int
    let inTable: Bool
    let styleID: String?
    /// Inside a block-level content control: readable, never edited.
    fileprivate(set) var blockLocked = false
    fileprivate(set) var fieldStackAtStart: [FieldFrame]
    fileprivate(set) var text: [Unicode.Scalar] = []
    fileprivate(set) var pieces: [Piece] = []

    init(element: XMLElement, index: Int, inTable: Bool, styleID: String?, fieldStack: [FieldFrame]) {
        self.element = element
        self.index = index
        self.inTable = inTable
        self.styleID = styleID
        self.fieldStackAtStart = fieldStack
    }

    var string: String { String(String.UnicodeScalarView(text)) }

    func piece(containingInterior offset: Int) -> Piece? {
        pieces.first { $0.start < offset && offset < $0.end }
    }

    func pieces(in range: Range<Int>) -> [Piece] {
        pieces.filter { $0.length > 0 && $0.start < range.upperBound && $0.end > range.lowerBound }
    }

    func isEditable(_ range: Range<Int>) -> Bool {
        var covered = range.lowerBound
        for p in pieces where p.end > range.lowerBound && p.start < range.upperBound {
            guard p.editable else { return false }
            covered = max(covered, p.end)
        }
        return covered >= range.upperBound
    }
}

enum FieldFrame { case code, result }

/// Decides which tracked revisions count as visible text. The default shows the document the way
/// Word displays it with markup hidden ("Simple Markup" text): insertions in, deletions out.
struct RevisionView {
    var showInsertion: (String?) -> Bool = { _ in true }
    var showDeletion: (String?) -> Bool = { _ in false }
}

/// Walks a WordprocessingML body and builds a `ParagraphModel` for every paragraph outside
/// text boxes, tracking complex-field state across paragraphs.
struct ParagraphScanner {
    let names: WordNames
    var view = RevisionView()
    private var fieldStack: [FieldFrame] = []

    init(names: WordNames, view: RevisionView = RevisionView()) {
        self.names = names
        self.view = view
    }

    mutating func scanBody(_ body: XMLElement) -> [ParagraphModel] {
        var out: [ParagraphModel] = []
        collect(body, inTable: false, locked: false, into: &out)
        return out
    }

    private mutating func collect(_ element: XMLElement, inTable: Bool, locked: Bool, into out: inout [ParagraphModel]) {
        for child in element.elementChildren {
            guard let local = names.local(child) else { continue }
            switch local {
            case "p":
                let model = ParagraphModel(element: child, index: out.count, inTable: inTable,
                                           styleID: styleID(of: child), fieldStack: fieldStack)
                model.blockLocked = locked
                fill(model, locked: locked)
                out.append(model)
            case "sectPr", "tblPr", "tblGrid", "trPr", "tcPr":
                continue
            case "tc":
                collect(child, inTable: true, locked: locked, into: &out)
            case "sdt":
                // Content controls are often locked form fields; read them but never edit inside.
                collect(child, inTable: inTable, locked: true, into: &out)
            case "del", "moveFrom":
                if view.showDeletion(child.attr(names.q("id"))) {
                    collect(child, inTable: inTable, locked: true, into: &out)
                }
            default:
                collect(child, inTable: inTable, locked: locked, into: &out)
            }
        }
    }

    private func styleID(of p: XMLElement) -> String? {
        guard let pPr = p.elementChildren.first(where: { names.local($0) == "pPr" }),
              let style = pPr.elementChildren.first(where: { names.local($0) == "pStyle" }) else { return nil }
        return style.attr(names.q("val"))
    }

    /// Re-reads one paragraph after its runs were split.
    mutating func rescan(_ model: ParagraphModel) {
        fieldStack = model.fieldStackAtStart
        model.text = []
        model.pieces = []
        fill(model, locked: model.blockLocked)
    }

    private mutating func fill(_ model: ParagraphModel, locked: Bool) {
        walkInline(model.element, model: model, locked: locked, deleted: false)
    }

    private mutating func walkInline(_ element: XMLElement, model: ParagraphModel, locked: Bool, deleted: Bool) {
        for child in element.elementChildren {
            guard let local = names.local(child) else {
                let l = localName(child)
                if l == "oMath" || l == "oMathPara" {
                    appendOpaque(child, text: mathText(child), model: model)
                }
                // Other foreign markup (mc:AlternateContent etc.) carries no body text.
                continue
            }
            switch local {
            case "pPr":
                continue
            case "r":
                scanRun(child, model: model, locked: locked, deleted: deleted)
            case "hyperlink", "smartTag", "bdo", "dir", "customXml":
                walkInline(child, model: model, locked: locked, deleted: deleted)
            case "sdt":
                if let content = child.elementChildren.first(where: { names.local($0) == "sdtContent" }) {
                    walkInline(content, model: model, locked: true, deleted: deleted)
                }
            case "fldSimple":
                walkInline(child, model: model, locked: true, deleted: deleted)
            case "ins", "moveTo":
                if view.showInsertion(child.attr(names.q("id"))) {
                    walkInline(child, model: model, locked: true, deleted: deleted)
                }
            case "del", "moveFrom":
                if view.showDeletion(child.attr(names.q("id"))) {
                    walkInline(child, model: model, locked: true, deleted: true)
                }
            default:
                continue // bookmarks, comment ranges, proofing marks, permissions: zero width
            }
        }
    }

    private func mathText(_ element: XMLElement) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        func visit(_ e: XMLElement) {
            if localName(e) == "t" { out.append(contentsOf: (e.stringValue ?? "").unicodeScalars) }
            e.elementChildren.forEach(visit)
        }
        visit(element)
        return out
    }

    private func appendOpaque(_ node: XMLElement, text: [Unicode.Scalar], model: ParagraphModel) {
        guard !text.isEmpty else { return }
        model.pieces.append(Piece(node: node, start: model.text.count, length: text.count, editable: false))
        model.text.append(contentsOf: text)
    }

    private mutating func scanRun(_ run: XMLElement, model: ParagraphModel, locked: Bool, deleted: Bool) {
        var simple = true
        var inFieldResult = false
        var runText: [Unicode.Scalar] = []
        var textVisible: Bool { !fieldStack.contains(.code) }

        for c in run.elementChildren {
            guard let local = names.local(c) else { simple = false; continue }
            switch local {
            case "rPr":
                continue
            case "t":
                if deleted { simple = false } // stray w:t in a deletion: leave it alone
                if textVisible {
                    if !fieldStack.isEmpty { inFieldResult = true }
                    runText.append(contentsOf: (c.stringValue ?? "").unicodeScalars)
                }
            case "delText":
                if deleted && textVisible { runText.append(contentsOf: (c.stringValue ?? "").unicodeScalars) }
                if !deleted { simple = false }
            case "tab", "ptab":
                if local == "ptab" { simple = false }
                if textVisible { runText.append("\t") }
            case "br", "cr":
                if textVisible { runText.append("\n") }
            case "noBreakHyphen":
                if textVisible { runText.append("\u{2011}") }
            case "softHyphen", "lastRenderedPageBreak":
                continue
            case "fldChar":
                simple = false
                switch c.attr(names.q("fldCharType")) {
                case "begin": fieldStack.append(.code)
                case "separate": if !fieldStack.isEmpty { fieldStack[fieldStack.count - 1] = .result }
                case "end": if !fieldStack.isEmpty { fieldStack.removeLast() }
                default: break
                }
            case "sym":
                simple = false
                if textVisible { runText.append("\u{FFFC}") }
            default:
                // instrText, drawings, objects, note references, comment references, ruby…
                simple = false
            }
        }

        guard !runText.isEmpty else { return }
        let editable = simple && !locked && !deleted && !inFieldResult && fieldStack.isEmpty
        model.pieces.append(Piece(node: run, start: model.text.count, length: runText.count, editable: editable,
                                  inFieldResult: inFieldResult))
        model.text.append(contentsOf: runText)
    }
}

extension ParagraphScanner {
    /// The runs holding the begin and end marks of the complex field whose result contains `run`,
    /// when the whole field sits within one parent element.
    static func fieldBounds(of run: XMLElement, names: WordNames) -> (begin: XMLElement, end: XMLElement)? {
        guard let siblings = (run.parent as? XMLElement)?.elementChildren, let i = siblings.firstIndex(where: { $0 === run }) else { return nil }
        func marks(_ e: XMLElement) -> [String] {
            e.elementChildren.filter { names.local($0) == "fldChar" }.compactMap { $0.attr(names.q("fldCharType")) }
        }
        var depth = 0
        var begin: XMLElement?
        for j in stride(from: i - 1, through: 0, by: -1) {
            for m in marks(siblings[j]).reversed() {
                if m == "end" { depth += 1 } else if m == "begin" { if depth == 0 { begin = siblings[j] } else { depth -= 1 } }
            }
            if begin != nil { break }
        }
        depth = 0
        var end: XMLElement?
        for j in (i + 1)..<siblings.count {
            for m in marks(siblings[j]) {
                if m == "begin" { depth += 1 } else if m == "end" { if depth == 0 { end = siblings[j] } else { depth -= 1 } }
            }
            if end != nil { break }
        }
        guard let begin, let end else { return nil }
        return (begin, end)
    }

    /// Splits the editable run that straddles `offset` so a run boundary falls exactly there.
    /// Returns false when the offset sits inside text that must not be split.
    static func splitRun(_ piece: Piece, at offset: Int, names: WordNames) -> Bool {
        guard piece.editable, offset > piece.start, offset < piece.end else { return false }
        let run = piece.node
        var position = piece.start
        let tail = XMLElement(name: run.name ?? names.q("r"))
        for attribute in run.attributes ?? [] { tail.setAttr(attribute.name ?? "", attribute.stringValue ?? "") }

        var moving: [XMLElement] = []
        for c in run.elementChildren {
            let local = names.local(c) ?? ""
            if local == "rPr" {
                tail.addChild(cloneElement(c))
                continue
            }
            let length: Int
            switch local {
            case "t": length = (c.stringValue ?? "").unicodeScalars.count
            case "tab", "br", "cr", "noBreakHyphen": length = 1
            default: length = 0
            }
            if position >= offset {
                moving.append(c)
            } else if local == "t" && position + length > offset {
                let scalars = Array((c.stringValue ?? "").unicodeScalars)
                let cut = offset - position
                c.stringValue = String(String.UnicodeScalarView(scalars[..<cut]))
                c.setAttr("xml:space", "preserve")
                tail.addChild(names.textElement("t", String(String.UnicodeScalarView(scalars[cut...]))))
            }
            position += length
        }
        for c in moving {
            c.detach()
            tail.addChild(c)
        }
        run.insertSibling(tail, before: false)
        return true
    }
}

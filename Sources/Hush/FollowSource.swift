import AppKit
import ApplicationServices

/// Only the document where reading began is observed. A tab switch never causes
/// Hush to capture a different frontmost document.
struct FollowSource: @unchecked Sendable {
    let root: AXUIElement
    let pid: pid_t
    let name: String
    let anchor: SourceSpan?
    private let documentRoot: AXUIElement
    private let url: String?

    init(root: AXUIElement, pid: pid_t, name: String, anchor: SourceSpan?) {
        self.root = root
        self.pid = pid
        self.name = name
        self.anchor = anchor
        self.documentRoot = TextCapture.ancestors(root).first(where: { TextCapture.attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }) ?? root
        self.url = Self.address(documentRoot)
    }

    private static func address(_ node: AXUIElement) -> String? {
        if let url = TextCapture.attribute(node, kAXURLAttribute) as? URL { return url.absoluteString }
        return TextCapture.attribute(node, kAXURLAttribute) as? String
    }

    func snapshot(consumed: String) throws -> FollowSnapshot {
        guard AXIsProcessTrusted(), TextCapture.attribute(root, kAXRoleAttribute) != nil,
              TextCapture.attribute(documentRoot, kAXRoleAttribute) != nil,
              !TextCapture.isSecure(root), Self.address(documentRoot) == url else {
            throw HushError(message: "The original document closed or changed. Select text again to follow it.")
        }
        let full = try TextCapture.document(root: root, pid: pid, name: name)
        let values = full.spans.map(\.text)
        let preferredLeaf = anchor.flatMap { anchor in full.spans.firstIndex(where: { CFEqual($0.element, anchor.element) }) }
        var mapped = SourceTextMapper.map(selection: consumed, leaves: values,
            preferredLeaf: preferredLeaf, preferredOffset: preferredLeaf == nil ? nil : anchor.map { $0.elementOffset - $0.start })
        if mapped.isEmpty { mapped = SourceTextMapper.map(selection: consumed, leaves: values) }
        guard let last = mapped.last else {
            throw HushError(message: "The text already read changed or is no longer available. Select a passage again to continue.")
        }
        let mappedSpans = mapped.map { part in
            let original = full.spans[part.leaf]
            return SourceSpan(start: part.sourceStart, length: part.sourceLength, element: original.element,
                              elementOffset: original.elementOffset + part.leafOffset,
                              text: (original.text as NSString).substring(with: NSRange(location: part.leafOffset, length: part.leafLength)))
        }
        let end = full.spans[last.leaf].start + last.leafOffset + last.leafLength
        return FollowSnapshot(mappedSpans: mappedSpans,
                              tail: TextCapture.slice(full, range: NSRange(location: end, length: full.text.utf16.count - end)))
    }
}

struct FollowSnapshot: @unchecked Sendable {
    let mappedSpans: [SourceSpan]
    let tail: CapturedDocument
}

extension TextCapture {
    static func document(root: AXUIElement, pid: pid_t, name: String) throws -> CapturedDocument {
        let leaves = readableNodes(root)
        var text = "", spans: [SourceSpan] = []
        var previousBlock: AXUIElement?
        for leaf in leaves {
            // A chat composer is not continuation of the response being read.
            if !CFEqual(root, leaf), ["AXTextArea", "AXTextField"].contains(attribute(leaf, kAXRoleAttribute) as? String ?? "") { continue }
            guard let value = attribute(leaf, kAXValueAttribute) as? String, !value.isEmpty else { continue }
            let block = ancestors(leaf).first {
                ["AXParagraph", "AXHeading", "AXListItem", "AXTextArea", "AXTextField"].contains(attribute($0, kAXRoleAttribute) as? String ?? "")
            } ?? element(attribute(leaf, kAXParentAttribute)) ?? leaf
            if let previousBlock, !CFEqual(previousBlock, block) { text += "\n" }
            let start = text.utf16.count
            guard start + value.utf16.count <= maxLength else {
                throw HushError(message: "This document exceeds the reading limit. Select text in a smaller document to follow it.")
            }
            spans.append(SourceSpan(start: start, length: value.utf16.count, element: leaf, elementOffset: 0, text: value))
            text += value
            previousBlock = block
        }
        guard !text.isEmpty else { throw HushError(message: "The original document is temporarily unavailable.") }
        return CapturedDocument(text: text, source: name, pid: pid, spans: spans)
    }

    static func slice(_ document: CapturedDocument, range: NSRange) -> CapturedDocument {
        let text = (document.text as NSString).substring(with: range)
        let spans: [SourceSpan] = document.spans.compactMap { span in
            let overlap = NSIntersectionRange(NSRange(location: span.start, length: span.length), range)
            guard overlap.length > 0 else { return nil }
            let local = overlap.location - span.start
            return SourceSpan(start: overlap.location - range.location, length: overlap.length, element: span.element,
                              elementOffset: span.elementOffset + local,
                              text: (span.text as NSString).substring(with: NSRange(location: local, length: overlap.length)))
        }
        return CapturedDocument(text: text, source: document.source, pid: document.pid, spans: spans)
    }
}

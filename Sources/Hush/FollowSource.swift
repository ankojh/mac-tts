import AppKit
import ApplicationServices

enum FollowCaptureError: LocalizedError {
    case sourceChanged
    var errorDescription: String? { "The original document closed or changed. Select text again to follow it." }
}

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

    func snapshot(consumed: String, previousSpans: [SourceSpan]) throws -> FollowSnapshot {
        guard AXIsProcessTrusted(), TextCapture.attribute(root, kAXRoleAttribute) != nil,
              TextCapture.attribute(documentRoot, kAXRoleAttribute) != nil,
              !TextCapture.isSecure(root), Self.address(documentRoot) == url else {
            throw FollowCaptureError.sourceChanged
        }
        // Continue directly from the last verified AX position. Re-matching
        // the entire reading history can fail after unrelated page updates and
        // forces every poll to scan a potentially enormous article.
        if let cursor = previousSpans.last,
           let tail = TextCapture.continuation(after: cursor, root: root, pid: pid, name: name) {
            return FollowSnapshot(mappedSpans: previousSpans, tail: tail)
        }
        let full = try TextCapture.document(root: root, pid: pid, name: name, truncate: true)
        let values = full.spans.map(\.text)
        let preferredLeaf = anchor.flatMap { anchor in full.spans.firstIndex(where: { CFEqual($0.element, anchor.element) }) }
        var mapped = SourceTextMapper.map(selection: consumed, leaves: values,
            preferredLeaf: preferredLeaf, preferredOffset: preferredLeaf == nil ? nil : anchor.map { $0.elementOffset - $0.start })
        if mapped.isEmpty { mapped = SourceTextMapper.map(selection: consumed, leaves: values) }
        var sourceOffset = 0
        if mapped.isEmpty {
            // A renderer may replace old paragraphs while preserving the end
            // of the passage. A unique recent context can recover that cursor.
            let recent = String(consumed.suffix(200))
            sourceOffset = consumed.utf16.count - recent.utf16.count
            mapped = SourceTextMapper.map(selection: recent, leaves: values)
        }
        guard let last = mapped.last else {
            throw HushError(message: "The text already read changed or is no longer available. Select a passage again to continue.")
        }
        let mappedSpans = previousSpans.filter { $0.start + $0.length <= sourceOffset } + mapped.map { part in
            let original = full.spans[part.leaf]
            return SourceSpan(start: sourceOffset + part.sourceStart, length: part.sourceLength, element: original.element,
                              elementOffset: original.elementOffset + part.leafOffset,
                              text: (original.text as NSString).substring(with: NSRange(location: part.leafOffset, length: part.leafLength)))
        }
        let end = full.spans[last.leaf].start + last.leafOffset + last.leafLength
        let remainder = (full.text as NSString).substring(from: end)
        let length = TextCapture.continuationLength(remainder, limit: 6000)
        return FollowSnapshot(mappedSpans: mappedSpans,
                              tail: TextCapture.slice(full, range: NSRange(location: end, length: length)))
    }
}

struct FollowSnapshot: @unchecked Sendable {
    let mappedSpans: [SourceSpan]
    let tail: CapturedDocument
}

extension TextCapture {
    static func paragraphContainer(_ leaf: AXUIElement, root: AXUIElement) -> AXUIElement {
        let parents = ancestors(leaf)
        return parents.first {
            ["AXParagraph", "AXHeading", "AXListItem", "AXTextArea", "AXTextField"].contains(attribute($0, kAXRoleAttribute) as? String ?? "")
        } ?? parents.first {
            let role = attribute($0, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute($0, kAXSubroleAttribute) as? String ?? ""
            return role == "AXGroup" && !["AXStrongStyleGroup", "AXEmphasisStyleGroup", "AXSuperscriptStyleGroup", "AXSubscriptStyleGroup", "AXCodeStyleGroup"].contains(subrole)
        } ?? root
    }

    static func prefixLength(_ text: String, limit: Int) -> Int {
        let value = text as NSString
        var count = min(value.length, max(0, limit))
        if count > 0, count < value.length, (0xD800...0xDBFF).contains(value.character(at: count - 1)) { count -= 1 }
        return count
    }

    static func continuationLength(_ text: String, limit: Int) -> Int {
        let count = prefixLength(text, limit: limit)
        guard count < text.utf16.count, count > 0 else { return count }
        let prefix = (text as NSString).substring(to: count) as NSString
        let boundary = prefix.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        return boundary.location != NSNotFound && boundary.location > count / 2 ? NSMaxRange(boundary) : count
    }

    static func continuation(after cursor: SourceSpan, root: AXUIElement, pid: pid_t, name: String) -> CapturedDocument? {
        guard !isSecure(cursor.element),
              ancestors(cursor.element).contains(where: { CFEqual($0, root) }),
              let value = attribute(cursor.element, kAXValueAttribute) as? String else { return nil }
        let offset = cursor.elementOffset + cursor.length
        guard offset <= value.utf16.count,
              (value as NSString).substring(with: NSRange(location: cursor.elementOffset, length: cursor.length)) == cursor.text else { return nil }

        // Walk only siblings after the cursor, then the following siblings of
        // its ancestors. Never rescan text before the selected starting point.
        var seeds: [AXUIElement] = []
        var node = cursor.element
        var depth = 0
        while !CFEqual(node, root) {
            depth += 1
            guard depth <= 48 else { return nil }
            guard let parent = element(attribute(node, kAXParentAttribute)),
                  let children = attribute(parent, kAXChildrenAttribute) as? [AXUIElement],
                  let index = children.firstIndex(where: { CFEqual($0, node) }) else { return nil }
            seeds.append(contentsOf: children.dropFirst(index + 1))
            node = parent
        }
        let limit = 6000
        var text = "", spans: [SourceSpan] = []
        var reachedLimit = false
        var previousBlock = paragraphContainer(cursor.element, root: root)
        func append(_ leaf: AXUIElement, _ raw: String, offset: Int = 0) {
            guard !raw.isEmpty, text.utf16.count < limit else { return }
            let block = paragraphContainer(leaf, root: root)
            if !CFEqual(previousBlock, block) { text += "\n\n" }
            let count = continuationLength(raw, limit: limit - text.utf16.count)
            if count < raw.utf16.count { reachedLimit = true }
            guard count > 0 else { return }
            let part = (raw as NSString).substring(to: count)
            spans.append(SourceSpan(start: text.utf16.count, length: count, element: leaf, elementOffset: offset, text: part))
            text += part
            previousBlock = block
        }
        append(cursor.element, (value as NSString).substring(from: offset), offset: offset)
        let deadline = Date().addingTimeInterval(2)
        for seed in seeds {
            if reachedLimit || text.utf16.count >= limit || Date() >= deadline { break }
            for leaf in readableNodes(seed) {
                if reachedLimit || text.utf16.count >= limit || Date() >= deadline { break }
                if ["AXTextArea", "AXTextField"].contains(attribute(leaf, kAXRoleAttribute) as? String ?? "") { continue }
                if let value = attribute(leaf, kAXValueAttribute) as? String { append(leaf, value) }
            }
        }
        return CapturedDocument(text: text, source: name, pid: pid, spans: spans)
    }

    static func document(root: AXUIElement, pid: pid_t, name: String, truncate: Bool = false) throws -> CapturedDocument {
        let leaves = readableNodes(root)
        var text = "", spans: [SourceSpan] = []
        var previousBlock: AXUIElement?
        for leaf in leaves {
            if truncate && text.utf16.count >= maxLength { break }
            // A chat composer is not continuation of the response being read.
            if !CFEqual(root, leaf), ["AXTextArea", "AXTextField"].contains(attribute(leaf, kAXRoleAttribute) as? String ?? "") { continue }
            guard var value = attribute(leaf, kAXValueAttribute) as? String, !value.isEmpty else { continue }
            let block = paragraphContainer(leaf, root: root)
            if let previousBlock, !CFEqual(previousBlock, block) { text += "\n\n" }
            let start = text.utf16.count
            var clipped = false
            if start + value.utf16.count > maxLength {
                guard truncate else {
                    throw HushError(message: "This document exceeds the reading limit. Select text in a smaller document to follow it.")
                }
                value = (value as NSString).substring(to: prefixLength(value, limit: maxLength - start))
                clipped = true
            }
            if value.isEmpty { break }
            spans.append(SourceSpan(start: start, length: value.utf16.count, element: leaf, elementOffset: 0, text: value))
            text += value
            previousBlock = block
            if clipped { break }
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

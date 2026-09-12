import AppKit
import ApplicationServices

struct SourceSpan {
    let start: Int
    let length: Int
    let element: AXUIElement
    let elementOffset: Int
    let text: String
}

struct CapturedDocument: @unchecked Sendable {
    let id = UUID()
    let text: String
    let source: String
    let pid: pid_t?
    let spans: [SourceSpan]
    var followSource: FollowSource? = nil
}

enum TextCapture {
    static func maskAnnotations(_ attributed: NSAttributedString) -> String {
        let output = NSMutableString(string: attributed.string)
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, run, _ in
            let raised = attributes[NSAttributedString.Key(kAXSuperscriptTextAttribute.takeUnretainedValue() as String)] as? NSNumber
            let baseline = attributes[.superscript] as? NSNumber
            if (raised?.intValue ?? baseline?.intValue ?? 0) != 0 {
                output.replaceCharacters(in: run, with: String(repeating: " ", count: run.length))
            }
        }
        return output as String
    }

    /// Mask formatted annotations with the same number of UTF-16 units. Source
    /// coordinates still refer to the untouched original document.
    static func speakingText(_ document: CapturedDocument) -> String {
        let output = NSMutableString(string: document.text)
        let deadline = Date().addingTimeInterval(1.5)
        for span in document.spans {
            if Date() > deadline { break }
            // Wikipedia reference links can expose plain digits without their
            // brackets or superscript attribute. Identify their actual target.
            let reference = ancestors(span.element).prefix(5).contains { node in
                let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
                if ["AXSuperscriptStyleGroup", "AXSubscriptStyleGroup"].contains(subrole) { return true }
                let raw = attribute(node, kAXURLAttribute)
                let address = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                return address.contains("#cite_note") || address.contains("#cite_ref")
            }
            if reference {
                output.replaceCharacters(in: NSRange(location: span.start, length: span.length),
                                         with: String(repeating: " ", count: span.length))
                continue
            }
            var range = CFRange(location: span.elementOffset, length: span.length)
            guard let value = AXValueCreate(.cfRange, &range),
                  let attributed = parameter(span.element, kAXAttributedStringForRangeParameterizedAttribute, value) as? NSAttributedString,
                  attributed.string == span.text else { continue }
            let sourceRange = NSRange(location: span.start, length: span.length)
            if NSMaxRange(sourceRange) <= output.length {
                output.replaceCharacters(in: sourceRange, with: maskAnnotations(attributed))
            }
        }
        return output as String
    }

    static let maxLength = 100_000
    static let permissionDeniedMessage = "macOS is denying Accessibility access to this copy of Hush. If Hush is already enabled in Settings, quit Hush, remove its Accessibility entry with −, then add this app again with + and reopen it. A development rebuild can leave an older permission entry enabled. Clipboard reading still works."

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    static func string(for element: AXUIElement, range: CFRange) -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success else { return nil }
        return result as? String
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }

    static func capture(pid: pid_t, name: String, selectionOnly: Bool, follow: Bool = false) throws -> CapturedDocument {
        guard AXIsProcessTrusted() else {
            throw HushError(message: permissionDeniedMessage)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let focused = element(attribute(app, kAXFocusedUIElementAttribute))
        if let focused, isSecure(focused) {
            throw HushError(message: "Password fields cannot be read.")
        }
        func selected(_ node: AXUIElement) -> CapturedDocument? {
            guard !isSecure(node), let text = attribute(node, kAXSelectedTextAttribute) as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let spans = selectionSpans(text: text, node: node)
            let anchor = spans.first?.element ?? node
            let parents = ancestors(anchor)
            let web = parents.first(where: { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" })
            let main = parents.first(where: { attribute($0, kAXSubroleAttribute) as? String == "AXLandmarkMain" })
            // Continue into later paragraphs/messages in the same document,
            // rather than stopping at the initially selected article/message.
            let sourceRoot = main ?? web ?? parents.first(where: {
                ["AXTextArea", "AXTextField"].contains(attribute($0, kAXRoleAttribute) as? String ?? "")
            }) ?? parents.first(where: { attribute($0, kAXRoleAttribute) as? String == "AXScrollArea" }) ?? node
            return CapturedDocument(text: text, source: name + " · selection", pid: pid, spans: spans,
                followSource: follow ? FollowSource(root: sourceRoot, pid: pid, name: name, anchor: spans.first) : nil)
        }
        if selectionOnly, let focused, let result = selected(focused) { return try bounded(result) }

        let window = element(attribute(app, kAXFocusedWindowAttribute))
        let root = window ?? focused ?? app
        var nodes: [AXUIElement] = []
        var stack = [root]
        let deadline = Date().addingTimeInterval(2.5)
        var visited = Set<CFHashCode>()
        while let node = stack.popLast(), nodes.count < 1600, Date() < deadline {
            let hash = CFHash(node)
            guard visited.insert(hash).inserted, !isSecure(node) else { continue }
            nodes.append(node)
            if selectionOnly, let result = selected(node) { return try bounded(result) }
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu", "AXButton", "AXPopUpButton"].contains(role) { continue }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.prefix(500).reversed())
            }
        }
        if selectionOnly {
            throw HushError(message: "No accessible selection found. Select text and press ⌥Space, or copy it and choose Read clipboard.")
        }

        // Prefer an editable document's value. For web pages, use readable leaves
        // under AXWebArea; never concatenate parent values and their children.
        if let focused, let value = attribute(focused, kAXValueAttribute) as? String,
           value.utf16.count > 80,
           ["AXTextArea", "AXTextField"].contains(attribute(focused, kAXRoleAttribute) as? String ?? "") {
            return try bounded(CapturedDocument(text: value, source: name, pid: pid,
                spans: [SourceSpan(start: 0, length: value.utf16.count, element: focused, elementOffset: 0, text: value)]))
        }
        if let web = nodes.first(where: { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }) {
            return try document(root: web, pid: pid, name: name + " · accessible text")
        }
        return try document(root: root, pid: pid, name: name + " · accessible text")
    }

    static func readableNodes(_ root: AXUIElement) -> [AXUIElement] {
        var stack = [root], result: [AXUIElement] = []
        var count = 0
        let deadline = Date().addingTimeInterval(2)
        while let node = stack.popLast(), count < 2000, Date() < deadline {
            count += 1
            guard !isSecure(node) else { continue }
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
            if ["AXToolbar", "AXButton", "AXMenu", "AXPopUpButton"].contains(role) ||
                ["AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkSearch", "AXLandmarkComplementary"].contains(subrole) { continue }
            if ["AXStaticText", "AXTextArea", "AXTextField"].contains(role), let value = attribute(node, kAXValueAttribute) as? String, !value.isEmpty {
                result.append(node)
                continue
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.prefix(500).reversed())
            }
        }
        return result
    }

    static func ancestors(_ node: AXUIElement) -> [AXUIElement] {
        var nodes = [node]
        while nodes.count < 32, let parent = element(attribute(nodes.last!, kAXParentAttribute)),
              !nodes.contains(where: { CFEqual($0, parent) }) {
            nodes.append(parent)
            if attribute(parent, kAXRoleAttribute) as? String == "AXWindow" { break }
        }
        return nodes
    }

    private static func selectionSpans(text: String, node: AXUIElement) -> [SourceSpan] {
        var numeric: [SourceSpan] = []
        if let range = selectedRange(node), range.location >= 0, string(for: node, range: range) == text {
            numeric = [SourceSpan(start: 0, length: text.utf16.count, element: node, elementOffset: range.location, text: text)]
            // A web area's numeric range can return the right text but no bounds.
            // Prefer real text leaves for browsers; retain native editable ranges.
            if ["AXTextArea", "AXTextField", "AXStaticText"].contains(attribute(node, kAXRoleAttribute) as? String ?? ""),
               !ancestors(node).contains(where: { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }) {
                return numeric
            }
        }
        var root = node
        var preferred: AXUIElement?
        var preferredOffset: Int?
        // Browser/Electron selections can cross links, emphasis and paragraphs.
        // Their text markers identify the real endpoints even when a numeric
        // selected range is absent or relative to a different container.
        if let raw = attribute(node, "AXSelectedTextMarkerRange"), CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() {
            var markerRange = raw as! AXTextMarkerRange
            let endpoints = [AXTextMarkerRangeCopyStartMarker(markerRange), AXTextMarkerRangeCopyEndMarker(markerRange)] as CFArray
            if let ordered = parameter(node, "AXTextMarkerRangeForUnorderedTextMarkers", endpoints), CFGetTypeID(ordered) == AXTextMarkerRangeGetTypeID() {
                markerRange = ordered as! AXTextMarkerRange
            }
            let start = AXTextMarkerRangeCopyStartMarker(markerRange)
            let end = AXTextMarkerRangeCopyEndMarker(markerRange)
            if let first = element(parameter(node, "AXUIElementForTextMarker", start)),
               let last = element(parameter(node, "AXUIElementForTextMarker", end)) {
                preferred = first
                preferredOffset = (parameter(node, "AXIndexForTextMarker", start) as? NSNumber)?.intValue
                let firstParents = ancestors(first), lastParents = ancestors(last)
                root = firstParents.first(where: { candidate in lastParents.contains(where: { CFEqual(candidate, $0) }) }) ?? node
            }
        }
        if CFEqual(root, node), preferred == nil {
            root = ancestors(node).first(where: { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }) ?? node
        }
        let leaves = readableNodes(root)
        let values = leaves.map { attribute($0, kAXValueAttribute) as? String ?? "" }
        let preferredIndex = preferred.flatMap { target in leaves.firstIndex(where: { CFEqual($0, target) }) }
        var mapped = SourceTextMapper.map(selection: text, leaves: values, preferredLeaf: preferredIndex,
                                          preferredOffset: preferredIndex == nil ? nil : preferredOffset)
        // Marker endpoints may point at a container rather than the first text
        // leaf. A unique text match is still safe when that anchor cannot map.
        if mapped.isEmpty {
            mapped = SourceTextMapper.map(selection: text, leaves: values)
        }
        if mapped.isEmpty { return numeric }
        return mapped.map { span in
            SourceSpan(start: span.sourceStart, length: span.sourceLength, element: leaves[span.leaf],
                       elementOffset: span.leafOffset,
                       text: (values[span.leaf] as NSString).substring(with: NSRange(location: span.leafOffset, length: span.leafLength)))
        }
    }

    private static func bounded(_ document: CapturedDocument) throws -> CapturedDocument {
        guard document.text.utf16.count <= maxLength else {
            throw HushError(message: "Select up to 100,000 characters at a time.")
        }
        return document
    }
}

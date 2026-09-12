import AppKit
import ApplicationServices
import QuartzCore

enum HighlightGeometry {
    /// Adjacent word boxes on the same visual line become a single highlight.
    /// Different lines never become a large rectangle covering unrelated text.
    static func mergeLines(_ input: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in input.filter({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }).sorted(by: {
            abs($0.midY - $1.midY) > 3 ? $0.midY < $1.midY : $0.minX < $1.minX
        }) {
            if let index = result.indices.last,
               abs(result[index].midY - rect.midY) <= max(3, min(result[index].height, rect.height) * 0.25),
               rect.minX - result[index].maxX < 30 {
                result[index] = result[index].union(rect)
            } else {
                result.append(rect)
            }
        }
        return result
    }

    static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

private enum SourceBounds {
    static func rect(_ raw: CFTypeRef?) -> CGRect? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var result = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &result),
              result.width > 0, result.height > 0, result.width < 10_000, result.height < 10_000 else { return nil }
        return result
    }

    static func rangeBounds(_ node: AXUIElement, _ range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
        if let bounds = rect(TextCapture.parameter(node, kAXBoundsForRangeParameterizedAttribute, value)) { return bounds }
        // WebKit can expose marker bounds without numeric range bounds. Check
        // the marker's owner and text before accepting a converted global index.
        guard let web = TextCapture.ancestors(node).first(where: { TextCapture.attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }),
              let raw = TextCapture.parameter(web, "AXTextMarkerRangeForUIElement", node),
              CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        let markerRange = raw as! AXTextMarkerRange
        let origin = AXTextMarkerRangeCopyStartMarker(markerRange)
        guard let base = TextCapture.parameter(web, "AXIndexForTextMarker", origin) as? NSNumber,
              let first = TextCapture.parameter(web, "AXTextMarkerForIndex", NSNumber(value: base.intValue + range.location)),
              let last = TextCapture.parameter(web, "AXTextMarkerForIndex", NSNumber(value: base.intValue + NSMaxRange(range))),
              CFGetTypeID(first) == AXTextMarkerGetTypeID(), CFGetTypeID(last) == AXTextMarkerGetTypeID(),
              let owner = TextCapture.element(TextCapture.parameter(web, "AXUIElementForTextMarker", first)), CFEqual(owner, node) else { return nil }
        let selected = AXTextMarkerRangeCreate(kCFAllocatorDefault, first as! AXTextMarker, last as! AXTextMarker)
        guard let actual = TextCapture.parameter(web, "AXStringForTextMarkerRange", selected) as? String,
              let full = TextCapture.attribute(node, kAXValueAttribute) as? String,
              NSMaxRange(range) <= full.utf16.count,
              actual == (full as NSString).substring(with: range) else { return nil }
        return rect(TextCapture.parameter(web, "AXBoundsForTextMarkerRange", selected))
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = TextCapture.attribute(node, kAXPositionAttribute),
              let size = TextCapture.attribute(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let axPosition = position as! AXValue, axSize = size as! AXValue
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize,
              AXValueGetValue(axPosition, .cgPoint, &point), AXValueGetValue(axSize, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func rectangles(segment: ReadingSegment, document: CapturedDocument) -> [CGRect] {
        let target = NSRange(location: segment.start, length: segment.end - segment.start)
        let words = try! NSRegularExpression(pattern: #"\S+"#)
        var boxes: [CGRect] = []
        let deadline = Date().addingTimeInterval(0.7)
        for span in document.spans {
            let intersection = NSIntersectionRange(target, NSRange(location: span.start, length: span.length))
            guard intersection.length > 0 else { continue }
            if Date() > deadline { break }
            let local = intersection.location - span.start
            let range = NSRange(location: span.elementOffset + local, length: intersection.length)
            let expected = (span.text as NSString).substring(with: NSRange(location: local, length: intersection.length))
            let current = TextCapture.string(for: span.element, range: CFRange(location: range.location, length: range.length))
            let fullValue = current != expected ? TextCapture.attribute(span.element, kAXValueAttribute) as? String : nil
            let actual: String?
            if let fullValue, NSMaxRange(range) <= fullValue.utf16.count {
                actual = (fullValue as NSString).substring(with: range)
            } else {
                actual = current
            }
            guard actual == expected else { continue } // Never highlight stale/edited content.
            if let whole = rangeBounds(span.element, range) {
                let matches = words.matches(in: expected, range: NSRange(location: 0, length: expected.utf16.count))
                var individual: [CGRect] = []
                for match in matches.prefix(80) {
                    if Date() > deadline { break }
                    if let bounds = rangeBounds(span.element, NSRange(location: range.location + match.range.location, length: match.range.length)),
                       bounds.height < 160 {
                        individual.append(bounds)
                    }
                }
                if individual.isEmpty, whole.height < 100 { individual = [whole] }
                boxes.append(contentsOf: individual)
            } else if local == 0, intersection.length == span.length,
                      let value = TextCapture.attribute(span.element, kAXValueAttribute) as? String,
                      value == span.text, let whole = frame(span.element), whole.height < 100 {
                boxes.append(whole)
            }
        }
        return HighlightGeometry.mergeLines(boxes)
    }
}

private final class HighlightView: NSView {
    var isWord = false
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        (isWord ? NSColor.systemOrange.withAlphaComponent(0.48) : NSColor.systemYellow.withAlphaComponent(0.18)).setFill()
        shape.fill()
        NSColor.systemOrange.withAlphaComponent(0.95).setStroke()
        shape.lineWidth = 1.6
        shape.stroke()
    }
}

@MainActor
final class SourceHighlighter {
    private let isWord: Bool
    init(isWord: Bool = false) { self.isWord = isWord }
    private var panels: [NSPanel] = []
    private var key: String?
    private var inFlight = false
    private var revision = UUID()
    private var lastQuery = Date.distantPast
    var onAvailability: ((Bool) -> Void)?
    var onResolution: ((Bool) -> Void)?

    func hide() {
        revision = UUID()
        key = nil
        inFlight = false
        panels.forEach { $0.orderOut(nil) }
        onAvailability?(false)
    }

    private func sourceIsVisible(_ document: CapturedDocument) -> Bool {
        guard let pid = document.pid, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        // Clicking Hush's controls must not remove the highlight from the source.
        return front == pid || front == ProcessInfo.processInfo.processIdentifier
    }

    func show(segment: ReadingSegment, document: CapturedDocument) {
        guard sourceIsVisible(document) else { hide(); return }
        let nextKey = "\(document.id)-\(segment.id)"
        if inFlight && key == nextKey { return }
        if key == nextKey && Date().timeIntervalSince(lastQuery) < 0.18 { return }
        if key != nextKey {
            if !isWord { panels.forEach { $0.orderOut(nil) } }
            revision = UUID()
            key = nextKey
        }
        inFlight = true
        lastQuery = Date()
        let token = revision
        Task {
            let rects = await Task.detached(priority: .userInitiated) {
                SourceBounds.rectangles(segment: segment, document: document)
            }.value
            guard token == revision, key == nextKey else { return }
            inFlight = false
            guard sourceIsVisible(document) else { hide(); return }
            render(rects)
        }
    }

    private func render(_ sourceRects: [CGRect]) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let rects = sourceRects.map { HighlightGeometry.appKitRect($0, primaryTop: primaryTop) }
            .filter { rect in NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) }
        for (index, rect) in rects.prefix(30).enumerated() {
            if index >= panels.count {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let view = HighlightView()
                view.isWord = isWord
                panel.contentView = view
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.level = isWord ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.setAccessibilityElement(false)
                panels.append(panel)
            }
            let panel = panels[index]
            let next = rect.insetBy(dx: -3, dy: -2)
            if isWord, panel.isVisible, abs(panel.frame.midY - next.midY) < max(panel.frame.height, next.height) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.10
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(next, display: true)
                }
            } else { panel.setFrame(next, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for index in min(rects.count, panels.count)..<panels.count { panels[index].orderOut(nil) }
        onAvailability?(!rects.isEmpty)
        onResolution?(!rects.isEmpty)
    }
}

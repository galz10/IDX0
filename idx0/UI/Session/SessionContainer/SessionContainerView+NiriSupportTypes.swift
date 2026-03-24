import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct NiriResizeVisualizerState: Equatable {
    enum Kind: Equatable {
        case column
        case item
    }

    let kind: Kind
    let workspaceID: UUID
    let primaryColumnID: UUID
    let secondaryColumnID: UUID?
    let primaryItemID: UUID?
    let secondaryItemID: UUID?
}

struct NiriDropInsertionTarget: Equatable {
    let workspaceID: UUID
    let columnInsertionIndex: Int
}

struct NiriTileDragState: Equatable {
    let sessionID: UUID
    let workspaceID: UUID
    let columnID: UUID
    let itemID: UUID
    /// The column index where the tile originally started.
    let originColumnIndex: Int
    /// The item index where the tile originally started.
    let originItemIndex: Int
    /// The column index the tile currently occupies in the model.
    var currentColumnIndex: Int
    /// The item index the tile currently occupies in the model.
    var currentItemIndex: Int
    /// Raw gesture translation — tile follows this directly.
    var translation: CGSize = .zero
    /// Locked drag axis — determined from the initial drag direction.
    var axis: NiriTileDragAxis = .undecided

    enum NiriTileDragAxis: Equatable {
        case undecided
        case horizontal
        case vertical
    }
}

enum NiriEdgeAlignment {
    case leading
    case trailing
}

enum NiriVerticalEdgeAlignment {
    case top
    case bottom
}

enum NiriPanInputKind {
    case oneFingerDrag
    case twoFingerScroll

    var label: String {
        switch self {
        case .oneFingerDrag:
            return "1-finger drag"
        case .twoFingerScroll:
            return "2-finger scroll"
        }
    }
}

struct NiriCanvasMetrics: Equatable {
    var tileWidth: CGFloat
    var tileHeight: CGFloat
    var columnSpacing: CGFloat
    var itemSpacing: CGFloat
    var workspaceSpacing: CGFloat
    var headerHeight: CGFloat
    var originX: CGFloat
    var originY: CGFloat
    var containerWidth: CGFloat
    var containerHeight: CGFloat
    var canvasScale: CGFloat
    /// When set, the tile with this ID is zoomed to fill the viewport.
    var zoomedItemID: UUID?
}

struct NiriCanvasRuntimeState {
    var gesture = NiriGestureState(axis: .undecided, cumulative: .zero, isActive: false)
    var cameraOffset: CGSize = .zero
    var transientOffset: CGSize = .zero
    var lastDragTranslation: CGSize = .zero
    var lastContainerSize: CGSize = .zero
    var horizontalTracker = SwipeTracker()
    var verticalTracker = SwipeTracker()
    var inputKind: NiriPanInputKind = .oneFingerDrag
    var hotCornerArmed = true
}

enum NiriEdgeAutoScrollDirection {
    case left
    case right
    case up
    case down
}

struct NiriEdgeAutoScrollRuntime {
    var direction: NiriEdgeAutoScrollDirection
    var task: Task<Void, Never>
}

enum NiriCornerPosition {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

struct NiriResizeEdgeHandle: NSViewRepresentable {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis
    var onBegin: (() -> Void)? = nil
    let onDelta: (CGFloat) -> Void
    var onEnd: (() -> Void)? = nil

    func makeNSView(context: Context) -> NiriResizeEdgeNSView {
        let view = NiriResizeEdgeNSView()
        view.axis = axis
        view.onBegin = onBegin
        view.onDelta = onDelta
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: NiriResizeEdgeNSView, context: Context) {
        nsView.axis = axis
        nsView.onBegin = onBegin
        nsView.onDelta = onDelta
        nsView.onEnd = onEnd
        nsView.needsDisplay = true
        nsView.discardCursorRects()
        nsView.resetCursorRects()
    }
}

final class NiriResizeEdgeNSView: NSView {
    var axis: NiriResizeEdgeHandle.Axis = .horizontal
    var onBegin: (() -> Void)?
    var onDelta: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private var dragStartInWindow: NSPoint?
    private var lastTranslation: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        switch axis {
        case .horizontal:
            addCursorRect(bounds, cursor: .resizeLeftRight)
        case .vertical:
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartInWindow = event.locationInWindow
        lastTranslation = 0
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartInWindow else { return }
        let current = event.locationInWindow
        let translation: CGFloat
        switch axis {
        case .horizontal:
            translation = current.x - dragStartInWindow.x
        case .vertical:
            translation = current.y - dragStartInWindow.y
        }
        let delta = translation - lastTranslation
        lastTranslation = translation
        guard abs(delta) > 0.01 else { return }
        onDelta?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        dragStartInWindow = nil
        lastTranslation = 0
        onEnd?()
    }
}

struct NiriResizeCornerHandle: NSViewRepresentable {
    let corner: NiriCornerPosition
    var onBegin: (() -> Void)? = nil
    let onDelta: (CGFloat, CGFloat) -> Void
    var onEnd: (() -> Void)? = nil

    func makeNSView(context: Context) -> NiriResizeCornerNSView {
        let view = NiriResizeCornerNSView()
        view.corner = corner
        view.onBegin = onBegin
        view.onDelta = onDelta
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: NiriResizeCornerNSView, context: Context) {
        nsView.corner = corner
        nsView.onBegin = onBegin
        nsView.onDelta = onDelta
        nsView.onEnd = onEnd
        nsView.needsDisplay = true
        nsView.discardCursorRects()
        nsView.resetCursorRects()
    }
}

final class NiriResizeCornerNSView: NSView {
    var corner: NiriCornerPosition = .bottomTrailing
    var onBegin: (() -> Void)?
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private var dragStartInWindow: NSPoint?
    private var lastTranslationX: CGFloat = 0
    private var lastTranslationY: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch corner {
        case .topLeading, .bottomTrailing:
            // NW-SE diagonal — use the standard frameResize cursor
            cursor = NSCursor(image: Self.diagonalCursorImage(nwse: true), hotSpot: NSPoint(x: 8, y: 8))
        case .topTrailing, .bottomLeading:
            // NE-SW diagonal
            cursor = NSCursor(image: Self.diagonalCursorImage(nwse: false), hotSpot: NSPoint(x: 8, y: 8))
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartInWindow = event.locationInWindow
        lastTranslationX = 0
        lastTranslationY = 0
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartInWindow else { return }
        let current = event.locationInWindow
        let translationX = current.x - dragStartInWindow.x
        let translationY = current.y - dragStartInWindow.y
        let deltaX = translationX - lastTranslationX
        let deltaY = translationY - lastTranslationY
        lastTranslationX = translationX
        lastTranslationY = translationY
        guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return }
        onDelta?(deltaX, deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        dragStartInWindow = nil
        lastTranslationX = 0
        lastTranslationY = 0
        onEnd?()
    }

    private static func diagonalCursorImage(nwse: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if nwse {
                // NW-SE: top-left to bottom-right
                path.move(to: NSPoint(x: 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: rect.maxX - 2, y: 2))
                // Arrowheads
                path.move(to: NSPoint(x: 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: 6, y: rect.maxY - 2))
                path.move(to: NSPoint(x: 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: 2, y: rect.maxY - 6))
                path.move(to: NSPoint(x: rect.maxX - 2, y: 2))
                path.line(to: NSPoint(x: rect.maxX - 6, y: 2))
                path.move(to: NSPoint(x: rect.maxX - 2, y: 2))
                path.line(to: NSPoint(x: rect.maxX - 2, y: 6))
            } else {
                // NE-SW: top-right to bottom-left
                path.move(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: 2, y: 2))
                // Arrowheads
                path.move(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: rect.maxX - 6, y: rect.maxY - 2))
                path.move(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                path.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 6))
                path.move(to: NSPoint(x: 2, y: 2))
                path.line(to: NSPoint(x: 6, y: 2))
                path.move(to: NSPoint(x: 2, y: 2))
                path.line(to: NSPoint(x: 2, y: 6))
            }
            path.stroke()
            return true
        }
        return image
    }
}

struct NiriCanvasPanCaptureView: NSViewRepresentable {
    let onOneFingerDragBegan: () -> Void
    let onOneFingerDragChanged: (CGSize) -> Void
    let onOneFingerDragEnded: () -> Void
    let onTwoFingerScrollBegan: () -> Void
    let onTwoFingerScroll: (CGSize) -> Void
    let onTwoFingerScrollEnded: () -> Void
    let onPointerMoved: (CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> NiriCanvasPanCaptureNSView {
        let view = NiriCanvasPanCaptureNSView()
        view.onOneFingerDragBegan = onOneFingerDragBegan
        view.onOneFingerDragChanged = onOneFingerDragChanged
        view.onOneFingerDragEnded = onOneFingerDragEnded
        view.onTwoFingerScrollBegan = onTwoFingerScrollBegan
        view.onTwoFingerScroll = onTwoFingerScroll
        view.onTwoFingerScrollEnded = onTwoFingerScrollEnded
        view.onPointerMoved = onPointerMoved
        return view
    }

    func updateNSView(_ nsView: NiriCanvasPanCaptureNSView, context: Context) {
        nsView.onOneFingerDragBegan = onOneFingerDragBegan
        nsView.onOneFingerDragChanged = onOneFingerDragChanged
        nsView.onOneFingerDragEnded = onOneFingerDragEnded
        nsView.onTwoFingerScrollBegan = onTwoFingerScrollBegan
        nsView.onTwoFingerScroll = onTwoFingerScroll
        nsView.onTwoFingerScrollEnded = onTwoFingerScrollEnded
        nsView.onPointerMoved = onPointerMoved
    }
}

final class NiriCanvasPanCaptureNSView: NSView {
    var onOneFingerDragBegan: (() -> Void)?
    var onOneFingerDragChanged: ((CGSize) -> Void)?
    var onOneFingerDragEnded: (() -> Void)?
    var onTwoFingerScrollBegan: (() -> Void)?
    var onTwoFingerScroll: ((CGSize) -> Void)?
    var onTwoFingerScrollEnded: (() -> Void)?
    var onPointerMoved: ((CGPoint, CGSize) -> Void)?

    private var leftDragStartInWindow: NSPoint?
    private var rightDragStartInWindow: NSPoint?
    private var trackingAreaRef: NSTrackingArea?
    private var scrollGestureActive = false
    private var scrollEndWorkItem: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let newTracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTracking)
        trackingAreaRef = newTracking
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        onPointerMoved?(localPoint, bounds.size)
    }

    /// Returns true if the event has the canvas-pan modifier (Ctrl key).
    /// Unmodified clicks/scrolls pass through to the terminal underneath.
    private func hasPanModifier(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.control)
    }

    override func mouseDown(with event: NSEvent) {
        guard hasPanModifier(event) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        leftDragStartInWindow = event.locationInWindow
        onOneFingerDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartInWindow = leftDragStartInWindow else {
            super.mouseDragged(with: event)
            return
        }
        let current = event.locationInWindow
        onOneFingerDragChanged?(
            CGSize(
                width: current.x - dragStartInWindow.x,
                height: current.y - dragStartInWindow.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if leftDragStartInWindow != nil {
            onOneFingerDragEnded?()
            leftDragStartInWindow = nil
        } else {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard hasPanModifier(event) else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        rightDragStartInWindow = event.locationInWindow
        onOneFingerDragBegan?()
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let dragStartInWindow = rightDragStartInWindow else {
            super.rightMouseDragged(with: event)
            return
        }
        let current = event.locationInWindow
        onOneFingerDragChanged?(
            CGSize(
                width: current.x - dragStartInWindow.x,
                height: current.y - dragStartInWindow.y
            )
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        if rightDragStartInWindow != nil {
            onOneFingerDragEnded?()
            rightDragStartInWindow = nil
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Three-finger swipe (non-precise) or Ctrl+scroll for canvas pan;
        // unmodified precise scrolling passes through to the terminal for scrollback.
        guard event.hasPreciseScrollingDeltas else { return }
        guard hasPanModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        if !scrollGestureActive {
            scrollGestureActive = true
            onTwoFingerScrollBegan?()
        }
        onTwoFingerScroll?(
            CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        )
        scheduleScrollGestureEnd()
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            finishScrollGesture()
        }
    }

    private func scheduleScrollGestureEnd() {
        scrollEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishScrollGesture()
        }
        scrollEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func finishScrollGesture() {
        scrollEndWorkItem?.cancel()
        scrollEndWorkItem = nil
        if scrollGestureActive {
            scrollGestureActive = false
            onTwoFingerScrollEnded?()
        }
    }
}

import AppKit
import Foundation

@MainActor
final class GhosttyTerminalSurface: ObservableObject {
  let sessionID: UUID
  let workingDirectory: String
  let shellPath: String
  var surface: ghostty_surface_t?
  let view: GhosttyNativeView

  private(set) var callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
  private var pendingInputQueue: [PendingInputAction] = []

  private enum PendingInputAction {
    case text(String)
    case returnKey
  }

  init(
    sessionID: UUID,
    workingDirectory: String,
    shellPath: String,
    view: GhosttyNativeView,
    callbackContext: Unmanaged<GhosttySurfaceCallbackContext>
  ) {
    self.sessionID = sessionID
    self.workingDirectory = workingDirectory
    self.shellPath = shellPath
    self.view = view
    self.callbackContext = callbackContext

    callbackContext.takeUnretainedValue().surface = self
  }

  deinit {
    callbackContext?.release()
  }

  /// Create the ghostty surface. Must be called BEFORE the view is added
  /// to any layer-backed hierarchy, because ghostty sets up a layer-hosting
  /// view by setting layer before wantsLayer.
  func createSurfaceIfNeeded() {
    guard surface == nil else {
      flushPendingTextIfReady()
      return
    }
    GhosttyAppHost.shared.createSurface(for: self)
    flushPendingTextIfReady()
  }

  func destroy(freeSynchronously: Bool = false) {
    let context = callbackContext
    callbackContext = nil
    context?.takeUnretainedValue().surface = nil

    guard let surfaceToFree = surface else {
      view.prepareForSurfaceTeardown()
      context?.release()
      return
    }

    GhosttyAppHost.shared.removeSurface(self)
    surface = nil

    idx0_ghostty_surface_set_focus(surfaceToFree, false)
    idx0_ghostty_surface_set_occlusion(surfaceToFree, false)
    view.prepareForSurfaceTeardown()

    if freeSynchronously {
      idx0_ghostty_surface_free(surfaceToFree)
      context?.release()
      return
    }

    // Keep free asynchronous to avoid tearing down while AppKit/CALayer is
    // still in the same render transaction for this view.
    Task { @MainActor in
      idx0_ghostty_surface_free(surfaceToFree)
      context?.release()
    }
  }

  func resizeToCurrentViewBounds() {
    guard surface != nil else { return }
    let pointSize = view.bounds.size
    let backingSize = view.convertToBacking(NSRect(origin: .zero, size: pointSize)).size
    GhosttyAppHost.shared.resizeSurface(self, pointSize: pointSize, backingSize: backingSize)
  }

  func focus() {
    guard surface != nil else { return }
    GhosttyAppHost.shared.focusSurface(self)
  }

  func blur() {
    guard surface != nil else { return }
    GhosttyAppHost.shared.blurSurface(self)
  }

  func send(text: String) {
    guard !text.isEmpty else { return }
    guard surface != nil else {
      pendingInputQueue.append(.text(text))
      return
    }
    GhosttyAppHost.shared.sendText(text, to: self)
  }

  func sendReturnKey() {
    guard surface != nil else {
      pendingInputQueue.append(.returnKey)
      return
    }
    sendReturnKeyToSurface()
  }

  func refresh() {
    guard surface != nil else { return }
    GhosttyAppHost.shared.refreshSurface(self)
  }

  private func flushPendingTextIfReady() {
    guard surface != nil, !pendingInputQueue.isEmpty else { return }
    let queued = pendingInputQueue
    pendingInputQueue.removeAll(keepingCapacity: true)
    for action in queued {
      switch action {
      case let .text(text):
        GhosttyAppHost.shared.sendText(text, to: self)
      case .returnKey:
        sendReturnKeyToSurface()
      }
    }
  }

  private func sendReturnKeyToSurface() {
    guard let surface else { return }
    idx0_ghostty_surface_set_focus(surface, true)
    var press = ghostty_input_key_s()
    press.action = GHOSTTY_ACTION_PRESS
    press.keycode = 36 // Return key virtual key code on macOS
    press.mods = GHOSTTY_MODS_NONE
    press.consumed_mods = GHOSTTY_MODS_NONE
    press.composing = false
    press.unshifted_codepoint = 13
    "\r".withCString { ptr in
      press.text = ptr
      _ = idx0_ghostty_surface_key(surface, press)
    }

    var release = ghostty_input_key_s()
    release.action = GHOSTTY_ACTION_RELEASE
    release.keycode = 36
    release.mods = GHOSTTY_MODS_NONE
    release.consumed_mods = GHOSTTY_MODS_NONE
    release.text = nil
    release.composing = false
    release.unshifted_codepoint = 0
    _ = idx0_ghostty_surface_key(surface, release)
    GhosttyAppHost.shared.scheduleTick()
  }
}

final class GhosttyNativeView: NSView {
  weak var terminalSurface: GhosttyTerminalSurface?
  private var resizeDebounceItem: DispatchWorkItem?
  /// When true, layout-triggered resizes are suppressed (e.g. during overview scaling).
  var suppressResize = false

  override var acceptsFirstResponder: Bool {
    true
  }

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  /// Text accumulated by insertText during interpretKeyEvents
  private var keyTextAccumulator: [String]?
  /// Current marked (preedit/IME) text
  private var markedTextStorage = NSMutableAttributedString()
  private var markedRange_ = NSRange(location: NSNotFound, length: 0)
  private var selectedRange_ = NSRange(location: 0, length: 0)

  func prepareForSurfaceTeardown() {
    resizeDebounceItem?.cancel()
    resizeDebounceItem = nil

    if window?.firstResponder === self {
      window?.makeFirstResponder(nil)
    }

    terminalSurface = nil
    removeFromSuperview()
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    registerForDraggedTypes([.fileURL, .URL, .string])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }

    // Create the surface now that the view is in a window (deferred from makeSurface).
    // This matches cmux's approach where surface creation only happens once
    // the view has a window, so ghostty can get display ID and backing scale.
    terminalSurface?.createSurfaceIfNeeded()

    terminalSurface?.resizeToCurrentViewBounds()

    if window?.isKeyWindow == true {
      DispatchQueue.main.async { [weak self] in
        self?.terminalSurface?.focus()
      }
    }
  }

  override func layout() {
    super.layout()
    guard !suppressResize else { return }
    // Debounce resize to coalesce rapid layout changes (e.g. live sidebar drag).
    resizeDebounceItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.suppressResize else { return }
      terminalSurface?.resizeToCurrentViewBounds()
    }
    resizeDebounceItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      terminalSurface?.focus()
    }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      terminalSurface?.blur()
    }
    return resigned
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    terminalSurface?.focus()
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    idx0_ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func mouseUp(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    idx0_ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func mouseMoved(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else {
      super.rightMouseDown(with: event)
      return
    }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    idx0_ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func rightMouseUp(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    idx0_ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func rightMouseDragged(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }
    let pos = convertToSurfacePoint(event)
    idx0_ghostty_surface_mouse_pos(surface, pos.x, pos.y, modsFromEvent(event))
    GhosttyAppHost.shared.scheduleTick()
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else { return }

    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precision = event.hasPreciseScrollingDeltas

    if precision {
      // Match Ghostty's 2x multiplier for trackpad feel
      x *= 2
      y *= 2
    }

    // Pack scroll mods: bit 0 = precision, bits 1-3 = momentum phase
    var scrollMods: Int32 = 0
    if precision {
      scrollMods |= 0b0000_0001
    }
    let momentum: Int32 = switch event.momentumPhase {
    case .began: 1
    case .stationary: 2
    case .changed: 3
    case .ended: 4
    case .cancelled: 5
    case .mayBegin: 6
    default: 0
    }
    scrollMods |= momentum << 1

    idx0_ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    GhosttyAppHost.shared.scheduleTick()
  }

  private func convertToSurfacePoint(_ event: NSEvent) -> NSPoint {
    let local = convert(event.locationInWindow, from: nil)
    // Ghostty expects top-left origin
    return NSPoint(x: local.x, y: bounds.height - local.y)
  }

  // MARK: - Drag and Drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let fileURLs = droppedFileURLs(from: sender.draggingPasteboard)
    guard !fileURLs.isEmpty else { return false }

    let escapedPaths = fileURLs.map { GhosttyAppHost.shellEscapedCommand($0.path) }
    let insertion = escapedPaths.joined(separator: " ")
    guard !insertion.isEmpty else { return false }

    window?.makeFirstResponder(self)
    terminalSurface?.focus()
    terminalSurface?.send(text: "\(insertion) ")
    return true
  }

  private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    guard let nsURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
      return []
    }
    return nsURLs.compactMap { url in
      let asURL = url as URL
      return asURL.isFileURL ? asURL : nil
    }
  }

  // MARK: - Keyboard Events

  override func keyDown(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else {
      super.keyDown(with: event)
      return
    }

    // Command key events bypass ghostty and go to macOS menu handling
    if event.modifierFlags.contains(.command) {
      super.keyDown(with: event)
      return
    }

    // Ensure ghostty knows we have focus
    idx0_ghostty_surface_set_focus(surface, true)

    // Fast path for Ctrl-modified keys (Ctrl+C, Ctrl+D, etc.)
    // Bypass IME and send directly to ghostty
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.control) && !flags.contains(.option) && !hasMarkedText() {
      var keyEvent = ghostty_input_key_s()
      keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
      keyEvent.keycode = UInt32(event.keyCode)
      keyEvent.mods = modsFromEvent(event)
      keyEvent.consumed_mods = GHOSTTY_MODS_NONE
      keyEvent.composing = false
      keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

      let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
      if text.isEmpty {
        keyEvent.text = nil
        let handled = idx0_ghostty_surface_key(surface, keyEvent)
        if handled {
          GhosttyAppHost.shared.scheduleTick()
          return
        }
      } else {
        let handled = text.withCString { ptr -> Bool in
          keyEvent.text = ptr
          return idx0_ghostty_surface_key(surface, keyEvent)
        }
        if handled {
          GhosttyAppHost.shared.scheduleTick()
          return
        }
      }
    }

    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    // Translate mods to respect ghostty config (e.g. macos-option-as-alt)
    let translationModsGhostty = idx0_ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
    var translationMods = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      let hasFlag: Bool = switch flag {
      case .shift:
        (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
      case .control:
        (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
      case .option:
        (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
      case .command:
        (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
      default:
        translationMods.contains(flag)
      }
      if hasFlag {
        translationMods.insert(flag)
      } else {
        translationMods.remove(flag)
      }
    }

    let translationEvent: NSEvent = if translationMods == event.modifierFlags {
      event
    } else {
      NSEvent.keyEvent(
        with: event.type,
        location: event.locationInWindow,
        modifierFlags: translationMods,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: event.characters(byApplyingModifiers: translationMods) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      ) ?? event
    }

    // Set up text accumulator for interpretKeyEvents
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }

    let markedTextBefore = markedTextStorage.length > 0

    // Let the input system handle the event (for IME, dead keys, etc.)
    interpretKeyEvents([translationEvent])

    // Build the key event
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.mods = modsFromEvent(event)
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
    keyEvent.composing = markedTextStorage.length > 0 || markedTextBefore

    let accumulatedText = keyTextAccumulator ?? []
    if !accumulatedText.isEmpty {
      // Text from insertText (IME result) - not composing
      keyEvent.composing = false
      for text in accumulatedText {
        text.withCString { ptr in
          keyEvent.text = ptr
          keyEvent.consumed_mods = consumedModsFromFlags(translationMods, text: text)
          _ = idx0_ghostty_surface_key(surface, keyEvent)
        }
      }
    } else {
      // Get text for this key event
      if let text = textForKeyEvent(translationEvent) {
        text.withCString { ptr in
          keyEvent.text = ptr
          keyEvent.consumed_mods = consumedModsFromFlags(translationMods, text: text)
          _ = idx0_ghostty_surface_key(surface, keyEvent)
        }
      } else {
        keyEvent.text = nil
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        _ = idx0_ghostty_surface_key(surface, keyEvent)
      }
    }

    GhosttyAppHost.shared.scheduleTick()
  }

  override func keyUp(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else {
      super.keyUp(with: event)
      return
    }

    if event.modifierFlags.contains(.command) {
      super.keyUp(with: event)
      return
    }

    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_RELEASE
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.mods = modsFromEvent(event)
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.text = nil
    keyEvent.composing = false
    keyEvent.unshifted_codepoint = 0
    _ = idx0_ghostty_surface_key(surface, keyEvent)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface = terminalSurface?.surface else {
      super.flagsChanged(with: event)
      return
    }

    var keyEvent = ghostty_input_key_s()
    keyEvent.action = modifierActionFromFlagsChangedEvent(event)
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.mods = modsFromEvent(event)
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.text = nil
    keyEvent.composing = false
    keyEvent.unshifted_codepoint = 0
    _ = idx0_ghostty_surface_key(surface, keyEvent)
  }

  // MARK: - Input Helpers

  private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }

  private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags, text: String?) -> ghostty_input_mods_e {
    GhosttyKeyEventTranslator.consumedMods(flags: flags, text: text)
  }

  private func modifierActionFromFlagsChangedEvent(_ event: NSEvent) -> ghostty_input_action_e {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return GhosttyKeyEventTranslator.flagsChangedAction(keyCode: event.keyCode, flags: flags)
  }

  private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
    guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else {
      return 0
    }
    return scalar.value
  }

  private func textForKeyEvent(_ event: NSEvent) -> String? {
    guard let chars = event.characters, !chars.isEmpty else { return nil }

    if chars.count == 1, let scalar = chars.unicodeScalars.first {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      // Function keys (arrows, F1-F12, Home, End, etc.) use Unicode PUA
      // characters (0xF700+). Don't send these as text — ghostty handles
      // them by keycode.
      if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
        return nil
      }

      // If we have a control character, return the character without the
      // control modifier so ghostty's KeyEncoder can handle it
      if scalar.value < 0x20 {
        if flags.contains(.control) {
          return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        // Non-control-modified control chars (like Return, Tab, Escape)
        // should still be sent as text
        return chars
      }
    }

    return chars
  }
}

enum GhosttyKeyEventTranslator {
  static func consumedMods(flags: NSEvent.ModifierFlags, text: String?) -> ghostty_input_mods_e {
    guard let text, !text.isEmpty else { return GHOSTTY_MODS_NONE }
    var mods = GHOSTTY_MODS_NONE.rawValue
    // Control-key text (Tab, Return, Escape, etc.) should not consume Shift;
    // otherwise modified non-text keys lose their Shift semantics.
    if flags.contains(.shift), !isOnlyControlText(text) {
      mods |= GHOSTTY_MODS_SHIFT.rawValue
    }
    if flags.contains(.option) {
      mods |= GHOSTTY_MODS_ALT.rawValue
    }
    return ghostty_input_mods_e(rawValue: mods)
  }

  static func flagsChangedAction(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ghostty_input_action_e {
    guard let modifierFlag = modifierFlag(forKeyCode: keyCode) else {
      return GHOSTTY_ACTION_PRESS
    }
    return flags.contains(modifierFlag) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
  }

  private static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
    switch keyCode {
    case 56, 60:
      .shift
    case 59, 62:
      .control
    case 58, 61:
      .option
    case 54, 55:
      .command
    default:
      nil
    }
  }

  private static func isOnlyControlText(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return value < 0x20 || (0x7F ... 0x9F).contains(value)
    }
  }
}

// MARK: - NSTextInputClient

extension GhosttyNativeView: @preconcurrency NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String
    if let s = string as? String {
      text = s
    } else if let s = string as? NSAttributedString {
      text = s.string
    } else {
      return
    }

    // Clear any marked text since we're committing
    markedTextStorage.mutableString.setString("")
    markedRange_ = NSRange(location: NSNotFound, length: 0)
    selectedRange_ = NSRange(location: 0, length: 0)

    keyTextAccumulator?.append(text)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let s = string as? String {
      markedTextStorage.mutableString.setString(s)
    } else if let s = string as? NSAttributedString {
      markedTextStorage.setAttributedString(s)
    }

    if markedTextStorage.length > 0 {
      markedRange_ = NSRange(location: 0, length: markedTextStorage.length)
    } else {
      markedRange_ = NSRange(location: NSNotFound, length: 0)
    }
    selectedRange_ = selectedRange
  }

  func unmarkText() {
    markedTextStorage.mutableString.setString("")
    markedRange_ = NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange {
    selectedRange_
  }

  func markedRange() -> NSRange {
    markedRange_
  }

  func hasMarkedText() -> Bool {
    markedRange_.location != NSNotFound && markedRange_.length > 0
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let window else { return .zero }
    let viewRect = convert(bounds, to: nil)
    return window.convertToScreen(viewRect)
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  override func doCommand(by selector: Selector) {
    // interpretKeyEvents can route non-text keys (return, arrows, delete, etc.)
    // through AppKit command selectors. If they bubble to NSResponder defaults,
    // AppKit emits the system "dink" sound. Ghostty already handles the key
    // stream directly in keyDown/keyUp, so swallow these selectors while active.
    if terminalSurface?.surface != nil {
      return
    }
    super.doCommand(by: selector)
  }

  // MARK: - Edit Menu Actions (Cmd+C, Cmd+V, Cmd+A)

  private func performSurfaceAction(_ action: String) -> Bool {
    guard let surface = terminalSurface?.surface else { return false }
    return idx0_ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
  }

  @IBAction func copy(_ sender: Any?) {
    _ = performSurfaceAction("copy_to_clipboard")
  }

  @IBAction func paste(_ sender: Any?) {
    _ = performSurfaceAction("paste_from_clipboard")
  }

  @IBAction override func selectAll(_ sender: Any?) {
    if !performSurfaceAction("select_all") {
      super.selectAll(sender)
    }
  }
}

private extension NSScreen {
  var displayID: UInt32? {
    guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      return nil
    }
    return screenNumber.uint32Value
  }
}

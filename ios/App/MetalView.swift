import UIKit
import QuartzCore

/// The drawing surface. Catches the Apple Pencil, fingers, the pointer, scrolling, pinching and
/// the keyboard, and hands them to the Rust core.
///
/// Touch rules (modelled on Procreate and Affinity):
/// - Apple Pencil: draws and selects at once; its hover moves the pointer.
/// - Palm rejection: a finger that lands while the Pencil touches, hovers nearby or has just left
///   the screen is ignored, and so is a touch with a palm-sized contact area.
/// - One finger: acts like the pointer (it starts after a short move, or on lift for a tap).
/// - Two fingers: pan and pinch the canvas. A quick two-finger tap is Undo, three fingers Redo.
/// - A finger held still for half a second is a right click (context menu).
/// - Mouse and trackpad: clicks, hover, scroll wheel, two-finger scroll and pinch.
final class MetalView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // Hooks the view controller fills in.
    var onOpenFiles: (() -> Void)?
    var onSave: ((String, Data) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onPasteText: (() -> String?)?
    var onPasteHTML: (() -> String?)?
    var onCopyImage: ((Int, Int, Data) -> Void)?
    var onPasteImage: (() -> Data?)?
    /// True while a picker or alert is showing, so the view doesn't grab the keyboard back.
    var suspendFocus = false

    private var handle: UnsafeMutableRawPointer?
    private var startFailed = false
    private var link: CADisplayLink?
    private var softKeyboard = false
    private let emptyInput = UIView(frame: .zero)
    private var scratchText: UnsafeMutablePointer<CChar>?
    private var scratchBytes: UnsafeMutablePointer<UInt8>?
    private var held: (hid: UInt32, mods: UInt32, text: String?, start: CFTimeInterval, last: CFTimeInterval)?

    // Touch state
    private enum Mode { case idle, pending, pointer, gesture, consumed }
    private var mode: Mode = .idle
    private var fingers: [UITouch] = []
    private var fingerIds: [ObjectIdentifier: UInt64] = [:]
    private var fingerStarts: [ObjectIdentifier: CGPoint] = [:]
    private var nextFingerId: UInt64 = 1
    private var rejected = Set<ObjectIdentifier>()
    private var pendingStart: CGPoint = .zero
    private var lastFingerPoint: CGPoint = .zero
    private var lastMods: UInt32 = 0
    private var sessionStart: CFTimeInterval = 0
    private var sessionMax = 0
    private var sessionMoved: CGFloat = 0
    private var pencilTouch: UITouch?
    private var pencilLastActivity: CFTimeInterval = -10
    private var pencilHoverAt: CFTimeInterval = -10
    private var lastHoverWasPencil = false
    private var pointerButton: Int32 = 0
    private var deferred: [(due: CFTimeInterval, run: () -> Void)] = []
    private var logBudget = 40

    /// Touches wider than this (in points) are palms, not fingertips.
    private let palmRadius: CGFloat = 45
    /// A finger moving further than this (in points) starts a drag.
    private let dragSlop: CGFloat = 7
    /// A finger resting this long becomes a right click.
    private let longPress: CFTimeInterval = 0.5
    /// A finger landing this soon after the Pencil left the screen is a palm.
    private let pencilGrace: CFTimeInterval = 0.45
    /// A finger landing this soon after the Pencil was last seen hovering is a palm.
    private let hoverGrace: CFTimeInterval = 0.35

    // UITextInputTraits (no autocorrect while typing)
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        setupGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalView, _) in
            view.pushTheme()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        link?.invalidate()
        if let h = handle { fc_destroy(h) }
        if let s = scratchText { free(s) }
        if let b = scratchBytes { free(b) }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ensureHandle()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensureHandle()
        if let h = handle {
            let s = traitCollection.displayScale
            fc_resize(h, UInt32(max(1, bounds.width * s)), UInt32(max(1, bounds.height * s)), Float(s))
        }
    }

    private func ensureHandle() {
        guard handle == nil, !startFailed, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let s = traitCollection.displayScale
        contentScaleFactor = s
        metalLayer.contentsScale = s
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
        handle = fc_create(layerPtr, UInt32(bounds.width * s), UInt32(bounds.height * s), Float(s), makeCallbacks())
        if handle == nil { startFailed = true } else { pushTheme() }
    }

    private func pushTheme() {
        guard let h = handle else { return }
        fc_set_dark(h, traitCollection.userInterfaceStyle == .dark ? 1 : 0)
    }

    func saveState() { if let h = handle { fc_save_state(h) } }
    func setFocused(_ focused: Bool) { if let h = handle { fc_set_focused(h, focused ? 1 : 0) } }

    @objc private func tick() {
        guard let h = handle else { return }
        if !suspendFocus && !isFirstResponder { _ = becomeFirstResponder() }
        runDeferred()
        checkLongPress(h)
        repeatHeldKey()
        let flags = fc_frame(h)
        let wants = (flags & 2) != 0
        if wants != softKeyboard {
            softKeyboard = wants
            reloadInputViews()
        }
    }

    private func after(_ seconds: CFTimeInterval, _ run: @escaping () -> Void) {
        deferred.append((CACurrentMediaTime() + seconds, run))
    }

    private func runDeferred() {
        guard !deferred.isEmpty else { return }
        let now = CACurrentMediaTime()
        let due = deferred.filter { $0.due <= now }
        deferred.removeAll { $0.due <= now }
        for d in due { d.run() }
    }

    private func log(_ s: String) {
        guard logBudget > 0 else { return }
        logBudget -= 1
        fcLog(s)
    }

    // MARK: Callbacks from Rust

    fileprivate static func from(_ p: UnsafeMutableRawPointer?) -> MetalView? {
        p.map { Unmanaged<MetalView>.fromOpaque($0).takeUnretainedValue() }
    }

    fileprivate func stash(_ s: String?) -> UnsafePointer<CChar>? {
        if let old = scratchText { free(old) }
        scratchText = s.flatMap { strdup($0) }
        return scratchText.map { UnsafePointer($0) }
    }

    fileprivate func stashBytes(_ d: Data) -> UnsafePointer<UInt8>? {
        if let old = scratchBytes { free(old) }
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, d.count))
        d.copyBytes(to: p, count: d.count)
        scratchBytes = p
        return UnsafePointer(p)
    }

    private func makeCallbacks() -> FCCallbacks {
        let me = Unmanaged.passUnretained(self).toOpaque()
        return FCCallbacks(
            user: me,
            open_files: { u in MetalView.from(u)?.onOpenFiles?() },
            save_file: { u, name, data, len in
                guard let v = MetalView.from(u), let name = name else { return }
                let bytes = (data != nil && len > 0) ? Data(bytes: data!, count: len) : Data()
                v.onSave?(String(cString: name), bytes)
            },
            open_url: { u, url in
                guard let v = MetalView.from(u), let url = url else { return }
                v.onOpenURL?(String(cString: url))
            },
            copy_text: { u, text in
                guard let v = MetalView.from(u), let text = text else { return }
                v.onCopyText?(String(cString: text))
            },
            paste_text: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(v.onPasteText?())
            },
            paste_html: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(v.onPasteHTML?())
            },
            copy_image: { u, w, h, rgba, len in
                guard let v = MetalView.from(u), let rgba = rgba, len > 0 else { return }
                v.onCopyImage?(Int(w), Int(h), Data(bytes: rgba, count: len))
            },
            paste_png: { u, outLen in
                guard let v = MetalView.from(u), let outLen = outLen, let data = v.onPasteImage?(), !data.isEmpty else { return nil }
                outLen.pointee = data.count
                return v.stashBytes(data)
            },
            reduce_motion: { _ in UIAccessibility.isReduceMotionEnabled ? 1 : 0 },
            system_language: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(Locale.preferredLanguages.joined(separator: ","))
            }
        )
    }

    // MARK: Results from the view controller

    func deliverOpened(name: String, data: Data) {
        guard let h = handle else { return }
        name.withCString { n in
            data.withUnsafeBytes { raw in
                fc_open_file(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    /// The Open sheet was cancelled (`error` nil) or its file could not be read.
    func cancelOpen(error: String? = nil) {
        guard let h = handle else { return }
        if let e = error {
            e.withCString { fc_open_cancel(h, $0) }
        } else {
            fc_open_cancel(h, nil)
        }
    }

    /// The Save to Files sheet finished. `name` is the file the person chose.
    func saveResult(ok: Bool, name: String? = nil) {
        guard let h = handle else { return }
        if let name = name {
            name.withCString { fc_save_result(h, ok ? 1 : 0, $0) }
        } else {
            fc_save_result(h, ok ? 1 : 0, nil)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { softKeyboard ? nil : emptyInput }

    override func resignFirstResponder() -> Bool {
        held = nil
        return super.resignFirstResponder()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let h = handle else { return }
        if text == "\n" {
            fc_key(h, 0x28, 1, 0, 0)
            fc_key(h, 0x28, 0, 0, 0)
        } else {
            text.withCString { fc_text(h, $0) }
        }
    }

    func deleteBackward() {
        guard let h = handle else { return }
        fc_key(h, 0x2A, 1, 0, 0)
        fc_key(h, 0x2A, 0, 0, 0)
    }

    private func modBits(_ f: UIKeyModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.alternate) { m |= 4 }
        if f.contains(.command) { m |= 8 }
        return m
    }

    /// Only real typing keys type text: letters, digits, punctuation, space and the keypad.
    /// Arrows, Return, Tab, Escape, F-keys and the like are key presses, never text.
    private func typesText(_ hid: UInt32) -> Bool {
        if hid >= 0x04 && hid <= 0x27 { return true }                 // letters and digits
        if hid >= 0x2C && hid <= 0x38 { return true }                 // space and punctuation
        if hid >= 0x54 && hid <= 0x63 && hid != 0x58 { return true }  // keypad (not its Enter)
        return false
    }

    private func printable(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let ok = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        return ok ? s : nil
    }

    /// ⌘C, ⌘X and ⌘V go through the iPad's clipboard.
    private func clipboardShortcut(hid: UInt32, mods: UInt32) -> Bool {
        guard mods == 8, let h = handle else { return false }
        switch hid {
        case 0x06: fc_copy(h); return true
        case 0x1B: fc_cut(h); return true
        case 0x19:
            if UIPasteboard.general.hasStrings, let s = UIPasteboard.general.string, !s.isEmpty {
                s.withCString { fc_paste(h, $0) }
            } else {
                fc_paste(h, nil)   // a picture, or nothing: the app looks at the clipboard itself
            }
            return true
        default: return false
        }
    }

    /// A shortcut sent by the gestures and the Pencil: press and release together.
    private func sendShortcut(_ hid: UInt32, mods: UInt32) {
        guard let h = handle else { return }
        fc_key(h, hid, 1, 0, mods)
        fc_key(h, hid, 0, 0, mods)
    }

    private func handlePress(_ press: UIPress, down: Bool) -> Bool {
        guard let key = press.key, let h = handle else { return false }
        let hid = UInt32(key.keyCode.rawValue)
        if hid >= 0xE0 && hid <= 0xE7 { return true }   // a modifier key on its own
        let mods = modBits(key.modifierFlags)
        if down {
            if clipboardShortcut(hid: hid, mods: mods) { return true }
            fc_key(h, hid, 1, 0, mods)
            var text: String? = nil
            if typesText(hid) && mods & (8 | 2) == 0 { text = printable(key.characters) }
            if let t = text { t.withCString { fc_text(h, $0) } }
            let now = CACurrentMediaTime()
            held = (hid, mods, text, now, now)
        } else {
            fc_key(h, hid, 0, 0, mods)
            if held?.hid == hid { held = nil }
        }
        return true
    }

    private func repeatHeldKey() {
        guard let k = held, let h = handle else { return }
        let now = CACurrentMediaTime()
        if now - k.start > 0.4 && now - k.last > 0.035 {
            fc_key(h, k.hid, 1, 1, k.mods)
            if let t = k.text { t.withCString { fc_text(h, $0) } }
            held?.last = now
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: true) { rest.insert(p) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: false) { rest.insert(p) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held = nil
        super.pressesCancelled(presses, with: event)
    }

    // ⌘ shortcuts are claimed ahead of the system so ⌘Z, ⌘S, ⌘F and friends reach the app.
    private static let commandKeys: [UIKeyCommand] = {
        let letters = Array("abcdefgijklmnoprstuvxyz0123456789-=[];',./\\`").map { String($0) }
        let specials = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
                        UIKeyCommand.inputHome, UIKeyCommand.inputEnd]
        let mods: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .shift, .alternate]]
        var list: [UIKeyCommand] = []
        for input in letters + specials {
            for m in mods {
                let c = UIKeyCommand(input: input, modifierFlags: m, action: #selector(MetalView.commandKey(_:)))
                c.wantsPriorityOverSystemBehavior = true
                list.append(c)
            }
        }
        return list
    }()

    override var keyCommands: [UIKeyCommand]? { MetalView.commandKeys }

    private static func hid(for s: String) -> UInt32? {
        switch s {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        default: break
        }
        guard s.unicodeScalars.count == 1, let u = s.lowercased().unicodeScalars.first else { return nil }
        switch u {
        case "a"..."z": return 0x04 + (u.value - 97)
        case "1"..."9": return 0x1E + (u.value - 49)
        case "0": return 0x27
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }

    @objc func commandKey(_ cmd: UIKeyCommand) {
        guard let h = handle, let input = cmd.input, let hid = MetalView.hid(for: input) else { return }
        let mods = modBits(cmd.modifierFlags)
        if clipboardShortcut(hid: hid, mods: mods) { return }
        fc_key(h, hid, 1, 0, mods)
        fc_key(h, hid, 0, 0, mods)
    }

    // MARK: Apple Pencil buttons

    /// Double tap on the Pencil: the Move tool (V).
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        sendShortcut(0x19, mods: 0)
    }

    /// Squeeze on the Pencil Pro: the Hand tool (H).
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { sendShortcut(0x0B, mods: 0) }
    }

    // MARK: Pointer, scrolling, pinching

    private func setupGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.cancelsTouchesInView = false
        wheel.delegate = self
        addGestureRecognizer(wheel)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Hover of the mouse, the trackpad and the Apple Pencil. The Pencil is told apart by its
    /// distance from the screen (zOffset above zero).
    @objc private func hoverMoved(_ g: UIHoverGestureRecognizer) {
        guard let h = handle else { return }
        let now = CACurrentMediaTime()
        switch g.state {
        case .began, .changed:
            let isPencil = g.zOffset > 0
            lastHoverWasPencil = isPencil
            if isPencil { pencilHoverAt = now }
            log("hover: zOffset \(g.zOffset), treated as \(isPencil ? "Pencil" : "pointer")")
            // Never move the pointer under a pressed finger or Pencil.
            if pencilTouch == nil && mode != .pointer && mode != .gesture {
                let p = g.location(in: self)
                fc_pointer_moved(h, Float(p.x), Float(p.y))
            }
        case .ended, .cancelled:
            if lastHoverWasPencil { pencilHoverAt = now }
            if pencilTouch == nil && mode != .pointer && mode != .gesture {
                fc_pointer_gone(h)
            }
        default: break
        }
    }

    @objc private func pointerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { fc_scroll(h, Float(t.x), Float(t.y), modBits(g.modifierFlags)) }
    }

    /// Trackpad pinch. Two real fingers are handled by the touch code below instead.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let h = handle, g.state == .changed else { return }
        if mode == .gesture || fingers.count >= 2 || pencilTouch != nil {
            g.scale = 1
            return
        }
        fc_zoom(h, Float(g.scale))
        g.scale = 1
    }

    // MARK: Touches

    private func pencilIsNear(_ now: CFTimeInterval) -> Bool {
        pencilTouch != nil || now - pencilLastActivity < pencilGrace || now - pencilHoverAt < hoverGrace
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        lastMods = mods
        let now = CACurrentMediaTime()
        for t in touches {
            switch t.type {
            case .indirectPointer: beginMouse(t, event, mods, h)
            case .pencil: beginPencil(t, mods, now, h)
            default: beginFinger(t, mods, now, h)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let now = CACurrentMediaTime()
        for t in touches {
            switch t.type {
            case .indirectPointer:
                let p = t.location(in: self)
                fc_pointer_moved(h, Float(p.x), Float(p.y))
            case .pencil:
                guard t === pencilTouch else { break }
                pencilLastActivity = now
                // Every sample the Pencil took since the last frame, for smooth lines.
                for c in event?.coalescedTouches(for: t) ?? [t] {
                    let p = c.location(in: self)
                    fc_pointer_moved(h, Float(p.x), Float(p.y))
                }
            default: moveFinger(t, h)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?, cancelled: Bool) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        let now = CACurrentMediaTime()
        for t in touches {
            if rejected.remove(ObjectIdentifier(t)) != nil { continue }
            let p = t.location(in: self)
            switch t.type {
            case .indirectPointer:
                fc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 0, mods)
            case .pencil:
                guard t === pencilTouch else { break }
                fc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, mods)
                pencilTouch = nil
                pencilLastActivity = now
            default: endFinger(t, cancelled: cancelled, now: now, h)
            }
        }
    }

    // Mouse and trackpad clicks.
    private func beginMouse(_ t: UITouch, _ event: UIEvent?, _ mods: UInt32, _ h: UnsafeMutableRawPointer) {
        let p = t.location(in: self)
        pointerButton = (event?.buttonMask.contains(.secondary) ?? false) ? 1 : 0
        fc_pointer_moved(h, Float(p.x), Float(p.y))
        fc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 1, mods)
    }

    // The Apple Pencil: draws at once, and takes over from any finger.
    private func beginPencil(_ t: UITouch, _ mods: UInt32, _ now: CFTimeInterval, _ h: UnsafeMutableRawPointer) {
        dropFingers(h)
        pencilTouch = t
        pencilLastActivity = now
        let p = t.location(in: self)
        fc_pointer_moved(h, Float(p.x), Float(p.y))
        fc_pointer_button(h, Float(p.x), Float(p.y), 0, 1, mods)
    }

    /// The Pencil arrived while fingers were busy (a palm, say): let go of them.
    private func dropFingers(_ h: UnsafeMutableRawPointer) {
        switch mode {
        case .pointer:
            fc_pointer_button(h, Float(lastFingerPoint.x), Float(lastFingerPoint.y), 0, 0, lastMods)
        case .gesture:
            for f in fingers {
                let p = f.location(in: self)
                fc_touch(h, fingerIds[ObjectIdentifier(f)] ?? 0, 3, Float(p.x), Float(p.y), 0)
            }
        default: break
        }
        for f in fingers { rejected.insert(ObjectIdentifier(f)) }
        fingers.removeAll()
        fingerIds.removeAll()
        fingerStarts.removeAll()
        mode = .idle
    }

    // Fingers.
    private func beginFinger(_ t: UITouch, _ mods: UInt32, _ now: CFTimeInterval, _ h: UnsafeMutableRawPointer) {
        let key = ObjectIdentifier(t)
        if pencilIsNear(now) || t.majorRadius > palmRadius {
            rejected.insert(key)
            log("palm rejected: radius \(Int(t.majorRadius)), Pencil near: \(pencilIsNear(now))")
            return
        }
        log("finger: radius \(Int(t.majorRadius))")
        let p = t.location(in: self)
        fingers.append(t)
        fingerIds[key] = nextFingerId
        nextFingerId += 1
        fingerStarts[key] = p
        if fingers.count == 1 && mode == .idle {
            mode = .pending
            pendingStart = p
            lastFingerPoint = p
            sessionStart = now
            sessionMax = 1
            sessionMoved = 0
            return
        }
        sessionMax = max(sessionMax, fingers.count)
        switch mode {
        case .pending:
            // No pointer event was sent yet, so there is nothing to undo: two fingers pan and pinch.
            mode = .gesture
            for f in fingers { sendTouch(f, phase: 0, h) }
        case .pointer:
            fc_pointer_button(h, Float(lastFingerPoint.x), Float(lastFingerPoint.y), 0, 0, lastMods)
            fc_pointer_gone(h)
            mode = .gesture
            for f in fingers { sendTouch(f, phase: 0, h) }
        case .gesture:
            sendTouch(t, phase: 0, h)
        case .consumed, .idle:
            break
        }
    }

    private func sendTouch(_ t: UITouch, phase: Int32, _ h: UnsafeMutableRawPointer) {
        let p = t.location(in: self)
        fc_touch(h, fingerIds[ObjectIdentifier(t)] ?? 0, phase, Float(p.x), Float(p.y), 0)
    }

    private func moveFinger(_ t: UITouch, _ h: UnsafeMutableRawPointer) {
        let key = ObjectIdentifier(t)
        guard fingers.contains(where: { $0 === t }), let start = fingerStarts[key] else { return }
        let p = t.location(in: self)
        sessionMoved = max(sessionMoved, hypot(p.x - start.x, p.y - start.y))
        switch mode {
        case .pending:
            if hypot(p.x - pendingStart.x, p.y - pendingStart.y) > dragSlop {
                // The finger really moves: the press starts where the finger first landed.
                fc_pointer_moved(h, Float(pendingStart.x), Float(pendingStart.y))
                fc_pointer_button(h, Float(pendingStart.x), Float(pendingStart.y), 0, 1, lastMods)
                fc_pointer_moved(h, Float(p.x), Float(p.y))
                lastFingerPoint = p
                mode = .pointer
            }
        case .pointer:
            if t === fingers.first {
                fc_pointer_moved(h, Float(p.x), Float(p.y))
                lastFingerPoint = p
            }
        case .gesture:
            sendTouch(t, phase: 1, h)
        case .consumed, .idle:
            break
        }
    }

    private func endFinger(_ t: UITouch, cancelled: Bool, now: CFTimeInterval, _ h: UnsafeMutableRawPointer) {
        guard let index = fingers.firstIndex(where: { $0 === t }) else { return }
        let key = ObjectIdentifier(t)
        let p = t.location(in: self)
        switch mode {
        case .pending:
            if !cancelled {
                // A tap: press now, let go a moment later so the app sees a real click.
                let mods = lastMods
                fc_pointer_moved(h, Float(p.x), Float(p.y))
                fc_pointer_button(h, Float(p.x), Float(p.y), 0, 1, mods)
                after(0.03) { [weak self] in
                    guard let self = self, let h = self.handle else { return }
                    fc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, mods)
                    fc_pointer_gone(h)
                }
            }
        case .pointer:
            fc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, lastMods)
            fc_pointer_gone(h)
        case .gesture:
            sendTouch(t, phase: cancelled ? 3 : 2, h)
        case .consumed, .idle:
            break
        }
        fingers.remove(at: index)
        fingerIds[key] = nil
        fingerStarts[key] = nil
        if fingers.isEmpty {
            // A quick tap with two fingers is Undo, with three fingers Redo.
            if mode == .gesture && !cancelled && now - sessionStart < 0.35 && sessionMoved < 12 {
                if sessionMax == 2 { sendShortcut(0x1D, mods: 8) }
                if sessionMax == 3 { sendShortcut(0x1D, mods: 9) }
            }
            mode = .idle
        }
    }

    /// A finger resting on the canvas for half a second is a right click.
    private func checkLongPress(_ h: UnsafeMutableRawPointer) {
        guard mode == .pending, CACurrentMediaTime() - sessionStart > longPress else { return }
        let p = pendingStart
        mode = .consumed
        fc_pointer_moved(h, Float(p.x), Float(p.y))
        fc_pointer_button(h, Float(p.x), Float(p.y), 1, 1, 0)
        after(0.03) { [weak self] in
            guard let self = self, let h = self.handle else { return }
            fc_pointer_button(h, Float(p.x), Float(p.y), 1, 0, 0)
        }
    }
}

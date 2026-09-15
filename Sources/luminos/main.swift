//
//  luminos — DDC brightness companion for external monitors on Apple Silicon
//
//  - Menu bar app: gamma slider (magnetic snaps + haptics) for dark movies,
//    sync toggle to mirror built-in brightness to the external monitor,
//    movie mode (hardware backlight boost).
//  - --sync: keep the external monitor mapped to the built-in display's
//    brightness (polls once per second).
//  - --movie: toggle movie mode in the running daemon.
//  - --test: DDC read/write probe.
//
//  Requires: m1ddc installed. (Key interception was dropped: TCC binds to
//  the ad-hoc cdhash, so Accessibility grants break on every rebuild.)
//

import Cocoa

// MARK: - Config

let M1DDC = "/opt/homebrew/bin/m1ddc"
let MOVIE_FLAG = "/tmp/luminos_movie_toggle"     // --movie → daemon handoff (timestamped)
let TEST_PAUSE_FLAG = "/tmp/luminos_test_pause"  // --test suspends the daemon's sync writes
let SYNC_MIN = 10                  // DDC luminance floor when syncing
let SYNC_MAX = 100
let SYNC_HYSTERESIS = 2            // ignore built-in changes smaller than this (mapped units)
let MOVIE_LUMINANCE = 100          // movie mode targets
let MOVIE_CONTRAST = 85

let GAMMA_MIN: Float = 0.8
let GAMMA_MAX: Float = 2.4
let GAMMA_SNAPS: [Float] = [1.0, 1.3, 1.6, 2.2]
let GAMMA_SNAP_THRESHOLD: Float = 0.05

// MARK: - Palette

enum Palette {
    /// Gold accent in dark mode, plain label in light (per design).
    static let hero = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.35, alpha: 1)
        }
        return NSColor.labelColor
    }
    static let track = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.14)
            : NSColor(calibratedWhite: 0.0, alpha: 0.07)
    }
    static let pill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.16)
            : NSColor(calibratedWhite: 1.0, alpha: 1.0)
    }
    static let chip = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.08)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)
    }
}

// MARK: - DDC layer (via m1ddc)

enum DDC {
    /// All m1ddc traffic is serialized: concurrent DDC/CI transactions can
    /// collide on the bus, and sync writes must not interleave with the
    /// movie-mode read/save/write sequence.
    static let queue = DispatchQueue(label: "dev.luminos.ddc")

    /// m1ddc display index — resolved at startup (and again on DDC failure),
    /// since the index re-enumerates when monitors are replugged.
    static var displayArg = "1"

    @discardableResult
    static func run(_ args: [String]) -> String? {
        let out = runOnce(["display", displayArg] + args)
        if out != nil { return out }
        // the display index likely shifted (replug/reboot) — re-resolve, retry once
        resolveDisplay()
        return runOnce(["display", displayArg] + args)
    }

    @discardableResult
    static func runOnce(_ argv: [String]) -> String? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: M1DDC)
        p.arguments = argv
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // read to EOF BEFORE waiting — waiting first deadlocks once the
            // child fills the pipe buffer and blocks on write()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let s = String(data: data, encoding: .utf8)
            return s?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    /// Pick the first display m1ddc can address. `display list` prints lines
    /// like "[1] (null) (UUID)" and only lists DDC-capable (external)
    /// displays, so the first match is the monitor.
    static func resolveDisplay() {
        guard let out = runOnce(["display", "list"]),
              let re = try? NSRegularExpression(pattern: #"\[(\d+)\]"#),
              let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range(at: 1), in: out) else { return }
        let idx = String(out[r])
        guard idx != displayArg else { return }  // don't spam the log on repeated failures
        displayArg = idx
        NSLog("luminos: m1ddc display resolved to index \(displayArg)")
    }

    static func getLuminance() -> Int? { run(["get", "luminance"]).flatMap(Int.init) }
    static func getContrast() -> Int? { run(["get", "contrast"]).flatMap(Int.init) }
    @discardableResult
    static func setLuminance(_ v: Int) -> String? { run(["set", "luminance", "\(max(0, min(100, v)))"]) }
    @discardableResult
    static func setContrast(_ v: Int) -> String? { run(["set", "contrast", "\(max(0, min(100, v)))"]) }
}

// MARK: - Movie mode (DDC backlight boost)

final class MovieMode {
    private struct Save: Codable { let lum: Int; let con: Int }
    private static let stateFile = NSHomeDirectory() + "/Library/Application Support/Luminos/movie-state.json"

    /// Main-thread-confined state: `tick` runs on the main run loop and menu
    /// actions arrive on the main thread, so no locking is needed as long as
    /// nothing mutates MovieMode from a background queue (DDC work itself is
    /// serialized on DDC.queue).
    private var saved: (lum: Int, con: Int)?
    /// A restore whose DDC writes haven't reached the panel yet — left either
    /// by a previous run (crash/quit/deploy while movie mode was on) or by a
    /// failed toggle-off. Retried once per tick until it lands.
    private var pendingRestore: (lum: Int, con: Int)?
    private var restoreInFlight = false

    var isOn: Bool { saved != nil }

    /// Called once at startup: adopt a state file left by an earlier run so
    /// the monitor isn't stranded at 100/85 after a crash or deploy.
    func ingestPersistedState() {
        guard saved == nil, pendingRestore == nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: Self.stateFile)),
              let s = try? JSONDecoder().decode(Save.self, from: data) else { return }
        NSLog("luminos: persisted movie state \(s.lum)/\(s.con) found; will restore")
        pendingRestore = (s.lum, s.con)
    }

    /// Push any outstanding restore to the panel. Returns true while a
    /// restore is still outstanding (sync must hold off until it lands).
    @discardableResult
    func restoreOutstanding() -> Bool {
        guard let s = pendingRestore, !restoreInFlight else { return pendingRestore != nil }
        restoreInFlight = true
        DDC.queue.async { [weak self] in
            let ok = DDC.setLuminance(s.lum) != nil && DDC.setContrast(s.con) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.restoreInFlight = false
                guard ok else {
                    NSLog("luminos: movie restore \(s.lum)/\(s.con) failed; will retry")
                    return
                }
                NSLog("luminos: restored movie state \(s.lum)/\(s.con)")
                self.pendingRestore = nil
                try? FileManager.default.removeItem(atPath: Self.stateFile)
                sync.invalidate()
            }
        }
        return true
    }

    /// Synchronous best-effort restore on quit (applicationWillTerminate).
    func restoreNowIfOn() {
        guard let s = saved else { return }
        let ok = DDC.queue.sync { DDC.setLuminance(s.lum) != nil && DDC.setContrast(s.con) != nil }
        guard ok else {
            NSLog("luminos: quit restore failed; state file kept for next launch")
            return
        }
        saved = nil
        pendingRestore = nil
        try? FileManager.default.removeItem(atPath: Self.stateFile)
        NSLog("luminos: restored movie state \(s.lum)/\(s.con) on quit")
    }

    /// Main thread only.
    func toggle() {
        if let s = saved {
            saved = nil
            pendingRestore = s
            NSLog("luminos: movie mode off (restoring \(s.lum)/\(s.con))")
            restoreOutstanding()
        } else {
            pendingRestore = nil  // an explicit re-entry supersedes a pending restore
            let (l, c) = DDC.queue.sync { (DDC.getLuminance(), DDC.getContrast()) }
            guard let l, let c, (0...100).contains(l), (0...100).contains(c) else {
                NSLog("luminos: movie mode on failed (bad DDC read)")
                return
            }
            saved = (l, c)
            persist((l, c))
            DDC.queue.async {
                let ok = DDC.setLuminance(MOVIE_LUMINANCE) != nil && DDC.setContrast(MOVIE_CONTRAST) != nil
                if !ok { NSLog("luminos: movie mode boost writes failed (panel unavailable?)") }
            }
            NSLog("luminos: movie mode on (saved \(l)/\(c))")
        }
    }

    private func persist(_ s: (lum: Int, con: Int)) {
        let dir = (Self.stateFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Save(lum: s.lum, con: s.con)) {
            try? data.write(to: URL(fileURLWithPath: Self.stateFile))
        }
    }
}

// MARK: - Built-in display brightness

/// Real ABI: int DisplayServicesGetBrightness(int display, float *brightness)
typealias DSGetBrightnessFunc = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

final class BuiltinBrightness {
    private var getFn: DSGetBrightnessFunc?
    private let builtinID: CGDirectDisplayID?

    init() {
        builtinID = Self.builtinDisplayID()
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let h = dlopen(path, RTLD_LAZY),
           let sym = dlsym(h, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: DSGetBrightnessFunc.self)
        }
    }

    /// The first online display marked built-in (nil in clamshell mode).
    static func builtinDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Fallback: parse corebrightnessdiag status-info. Spawns a subprocess —
    /// expensive, so only used when the DisplayServices path above fails.
    /// (IOKit's IODisplayGetFloatParameter returns a frozen registry value on
    /// M1 — do not use it.)
    private func coreBrightnessValue() -> Float? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/corebrightnessdiag")
        p.arguments = ["status-info"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // read to EOF BEFORE waiting — waiting first deadlocks once the child
        // fills the pipe buffer (this dump is far larger than 64 KB)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8),
              let re = try? NSRegularExpression(
                  pattern: #"<key>DisplayBrightness</key>\s*<dict>\s*<key>Brightness</key>\s*<real>([0-9.]+)</real>"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Float(s[r])
    }

    func value() -> Float? {
        if let f = getFn, let id = builtinID {
            var v: Float = -1
            if f(id, &v) == 0, v >= 0 { return v }
        }
        return coreBrightnessValue()
    }
}

// MARK: - Sync engine

final class SyncEngine {
    let builtin = BuiltinBrightness()
    var enabled = false
    /// Last luminance the panel actually accepted. Main-thread only.
    var lastSent: Int?
    private var writeInFlight = false
    private var externalWasAbsent = false

    /// Forget the last accepted write so the next tick sends a fresh value
    /// (sync re-enable, movie-mode restore, …).
    func invalidate() { lastSent = nil }

    /// Poll once per second; call from main run loop timer.
    func tick(movieMode: MovieMode) {
        // --test suspends the daemon so its 1 s writes can't clobber the probe
        if FileManager.default.fileExists(atPath: TEST_PAUSE_FLAG) { return }

        // movie mode toggle requested via `luminos --movie`
        if let data = FileManager.default.contents(atPath: MOVIE_FLAG) {
            try? FileManager.default.removeItem(atPath: MOVIE_FLAG)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ts = Double(text) {
                if Date().timeIntervalSince1970 - ts > 10 {
                    NSLog("luminos: ignored stale movie flag")
                } else {
                    movieMode.toggle()
                }
            } else {
                NSLog("luminos: ignored unparsable movie flag")
            }
        }

        // a pending movie restore takes priority over sync writes
        if movieMode.restoreOutstanding() { return }
        guard enabled, !movieMode.isOn else { return }
        // no external display online — skip before spawning any subprocess
        guard Gamma.externalDisplayID() != nil else {
            externalWasAbsent = true
            return
        }
        if externalWasAbsent {
            // the panel may have reset its backlight while gone
            externalWasAbsent = false
            lastSent = nil
        }
        guard let b = builtin.value(), b >= 0 else { return }
        let mapped = SYNC_MIN + Int((Float(SYNC_MAX - SYNC_MIN) * b).rounded())
        if writeInFlight { return }
        if let last = lastSent, abs(mapped - last) < SYNC_HYSTERESIS { return }
        writeInFlight = true
        DDC.queue.async { [weak self] in
            let out = DDC.setLuminance(mapped)
            DispatchQueue.main.async {
                guard let self else { return }
                self.writeInFlight = false
                if out != nil {
                    // record "sent" only once the panel accepted the write;
                    // a failure clears lastSent so the next tick retries
                    self.lastSent = mapped
                    NSLog("luminos: sync set luminance=\(mapped) (builtin=\(b))")
                } else {
                    self.lastSent = nil
                    NSLog("luminos: sync luminance write failed; will retry")
                }
            }
        }
    }
}

// MARK: - Gamma control (CoreGraphics transfer formula, per-display)

enum Gamma {
    private static let defaultsKey = "lastGamma"
    /// Last gamma applied or read. Main-thread state, persisted so the
    /// setting survives launches and can be re-applied after sleep/replug.
    private static var current: Float = 1.0

    /// The first online display that isn't the built-in one. Never cache the
    /// CGDirectDisplayID across calls — it changes on replug/reboot.
    static func externalDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        let builtin = BuiltinBrightness.builtinDisplayID()
        return ids.prefix(Int(count)).first { $0 != builtin }
    }

    static func get() -> Float {
        guard let id = externalDisplayID() else { return current }
        var rmin: Float = 0, rmax: Float = 1, rg: Float = 1
        var gmin: Float = 0, gmax: Float = 1, gg: Float = 1
        var bmin: Float = 0, bmax: Float = 1, bg: Float = 1
        if CGGetDisplayTransferByFormula(id, &rmin, &rmax, &rg, &gmin, &gmax, &gg, &bmin, &bmax, &bg) == .success {
            current = gg
        }
        return current
    }

    static func set(_ g: Float) {
        let v = max(GAMMA_MIN, min(GAMMA_MAX, g))
        current = v
        UserDefaults.standard.set(Double(v), forKey: defaultsKey)
        apply(v)
    }

    /// Push the remembered gamma back to the external display. CoreGraphics
    /// drops transfer functions whenever displays sleep or re-enumerate.
    static func reapply() { apply(current) }

    /// Seed from the persisted preference, else from the panel's current
    /// transfer function; write to the panel only in the first case.
    static func loadAtLaunch() {
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Double {
            current = max(GAMMA_MIN, min(GAMMA_MAX, Float(stored)))
            apply(current)
        } else {
            _ = get()
        }
    }

    private static func apply(_ v: Float) {
        guard let id = externalDisplayID() else { return }
        let err = CGSetDisplayTransferByFormula(id, 0, 1, v, 0, 1, v, 0, 1, v)
        if err != .success { NSLog("luminos: gamma set failed (err \(err.rawValue))") }
    }
}

// MARK: - UI helpers

private func makeLabel(_ text: String, _ size: CGFloat, _ color: NSColor,
                       weight: NSFont.Weight = .regular) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    return f
}

private func trackedLabel(_ text: String, _ size: CGFloat, _ color: NSColor,
                          weight: NSFont.Weight, tracking: CGFloat) -> NSTextField {
    let f = NSTextField(labelWithString: "")
    let attr = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ])
    f.attributedStringValue = attr
    return f
}

private func roundedView(_ frame: NSRect, _ color: NSColor, radius: CGFloat) -> NSView {
    let v = NSView(frame: frame)
    v.wantsLayer = true
    v.layer?.backgroundColor = color.cgColor
    v.layer?.cornerRadius = radius
    return v
}

// MARK: - Capsule slider cell (rounded track + iOS-style knob)

final class CapsuleSliderCell: NSSliderCell {
    private let trackH: CGFloat = 28

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let r = NSRect(x: rect.minX, y: rect.midY - trackH / 2, width: rect.width, height: trackH)
        Palette.track.setFill()
        NSBezierPath(roundedRect: r, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: trackH / 2, yRadius: trackH / 2).setClip()
        // filled portion up to the knob
        let filled = NSRect(x: r.minX, y: r.minY, width: knobRect(flipped: flipped).midX - r.minX, height: r.height)
        NSColor(calibratedWhite: 1.0, alpha: 0.22).setFill()
        filled.fill()
        // tick notches at the labeled scale points
        NSColor.tertiaryLabelColor.setFill()
        for t: Float in [0.8, 1.2, 1.6, 2.0, 2.4] {
            let frac = CGFloat((t - GAMMA_MIN) / (GAMMA_MAX - GAMMA_MIN))
            let x = r.minX + frac * r.width
            NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: r.maxY - 7, width: 1.5, height: 5),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 22
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.3)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - Magnetic slider

final class GammaSlider: NSSlider {}

// MARK: - Preset capsule (segmented control, custom-drawn)

final class PresetCapsule: NSView {
    let values: [(String, Float)]
    var onSelect: (Float) -> Void
    private var buttons: [NSButton] = []
    private var pill: NSView!

    init(frame: NSRect, values: [(String, Float)], onSelect: @escaping (Float) -> Void) {
        self.values = values
        self.onSelect = onSelect
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.track.cgColor
        layer?.cornerRadius = frame.height / 2

        pill = roundedView(.zero, Palette.pill, radius: (frame.height - 8) / 2)
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.15
        pill.layer?.shadowRadius = 2
        pill.layer?.shadowOffset = NSSize(width: 0, height: -1)
        addSubview(pill)

        let bw = frame.width / CGFloat(values.count)
        for (i, v) in values.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            b.isBordered = false
            b.frame = NSRect(x: bw * CGFloat(i), y: 0, width: bw, height: frame.height)
            b.tag = i
            addSubview(b)
            buttons.append(b)
        }
        highlight(-1) // set initial title colors
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: NSButton) {
        onSelect(values[sender.tag].1)
    }

    private func titleAttributes(active: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13, weight: active ? .semibold : .medium),
            .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
    }

    /// Move the highlight pill to the preset matching `g`, or hide it.
    func highlight(_ g: Float) {
        var idx: Int?
        for (i, v) in values.enumerated() where abs(v.1 - g) < 0.005 { idx = i }
        let bw = frame.width / CGFloat(values.count)
        if let i = idx {
            pill.isHidden = false
            pill.frame = NSRect(x: bw * CGFloat(i) + 4, y: 4, width: bw - 8, height: frame.height - 8)
        } else {
            pill.isHidden = true
        }
        for (j, b) in buttons.enumerated() {
            b.attributedTitle = NSAttributedString(string: values[j].0,
                                                   attributes: titleAttributes(active: j == idx))
        }
    }
}

// MARK: - Toggle row (icon chip + title/subtitle + switch)

final class ToggleRow: NSView {
    let toggle: NSSwitch

    init(frame: NSRect, icon: String, title: String, subtitle: String,
         target: AnyObject, action: Selector) {
        toggle = NSSwitch()
        super.init(frame: frame)

        let chip = roundedView(NSRect(x: 0, y: (frame.height - 30) / 2, width: 30, height: 30), Palette.chip, radius: 8)
        let img = NSImageView(frame: NSRect(x: 6, y: 6, width: 18, height: 18))
        img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        img.contentTintColor = .secondaryLabelColor
        img.imageScaling = .scaleProportionallyUpOrDown
        chip.addSubview(img)
        addSubview(chip)

        let t = makeLabel(title, 13, .labelColor, weight: .semibold)
        t.frame = NSRect(x: 40, y: frame.height - 22, width: 170, height: 17)
        addSubview(t)
        let s = makeLabel(subtitle, 10.5, .secondaryLabelColor)
        s.frame = NSRect(x: 40, y: frame.height - 39, width: 180, height: 14)
        addSubview(s)

        toggle.target = target
        toggle.action = action
        toggle.controlSize = .regular
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: frame.width - toggle.frame.width,
                                      y: (frame.height - toggle.frame.height) / 2)
        addSubview(toggle)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Status bar UI

final class StatusBar: NSObject {
    static let menuW: CGFloat = 300

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var liveBadge: NSView!
    private var heroValue: NSTextField!
    private var slider: GammaSlider!
    private var capsule: PresetCapsule!
    private var syncRow: ToggleRow!
    private var movieRow: ToggleRow!

    private var lastSnapped: Float?

    override init() {
        super.init()
        if let btn = item.button {
            if let path = Bundle.main.path(forResource: "StatusIcon", ofType: "png"),
               let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Luminos")
            }
        }

        let menu = NSMenu()
        menu.addItem(makeHeaderItem())
        menu.addItem(makeGammaItem())
        menu.addItem(makePresetsItem())
        menu.addItem(.separator())
        syncRow = ToggleRow(frame: rowFrame(), icon: "rectangle.on.rectangle",
                            title: "Sync with built-in display", subtitle: "Auto-adjusts with MacBook",
                            target: self, action: #selector(toggleSync))
        menu.addItem(item(with: syncRow))
        movieRow = ToggleRow(frame: rowFrame(), icon: "film",
                             title: "Movie Mode", subtitle: "Backlight boost for dark scenes",
                             target: self, action: #selector(toggleMovie))
        menu.addItem(item(with: movieRow))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luminos", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
    }

    private func rowFrame() -> NSRect { NSRect(x: 0, y: 0, width: StatusBar.menuW - 28, height: 48) }

    private func item(with v: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = NSView(frame: NSRect(x: 0, y: 0, width: StatusBar.menuW, height: v.frame.height + 8))
        v.frame.origin = NSPoint(x: 14, y: 4)
        i.view?.addSubview(v)
        return i
    }

    // MARK: Header (icon chip, name, status, LIVE badge)

    private func makeHeaderItem() -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: StatusBar.menuW, height: 64))

        let chip = roundedView(NSRect(x: 18, y: 12, width: 40, height: 40), Palette.chip, radius: 10)
        let img = NSImageView(frame: NSRect(x: 9, y: 9, width: 22, height: 22))
        img.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        img.contentTintColor = .labelColor
        img.imageScaling = .scaleProportionallyUpOrDown
        chip.addSubview(img)
        v.addSubview(chip)

        // status dot
        let dot = roundedView(NSRect(x: 46, y: 12, width: 10, height: 10), .systemGreen, radius: 5)
        dot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        dot.layer?.borderWidth = 1.5
        v.addSubview(dot)

        let title = makeLabel("Luminos", 16, .labelColor, weight: .bold)
        title.frame = NSRect(x: 68, y: 30, width: 150, height: 21)
        v.addSubview(title)
        let sub = makeLabel("Mi Monitor", 11.5, .secondaryLabelColor)
        sub.frame = NSRect(x: 68, y: 13, width: 150, height: 15)
        v.addSubview(sub)

        liveBadge = NSView(frame: NSRect(x: StatusBar.menuW - 70, y: 24, width: 52, height: 22))
        liveBadge.wantsLayer = true
        liveBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
        liveBadge.layer?.cornerRadius = 11
        let lt = makeLabel("LIVE", 10, .systemGreen, weight: .bold)
        lt.alignment = .center
        lt.frame = NSRect(x: 0, y: 3, width: 52, height: 15)
        liveBadge.addSubview(lt)
        v.addSubview(liveBadge)

        let i = NSMenuItem()
        i.view = v
        return i
    }

    // MARK: Gamma slider section

    private func makeGammaItem() -> NSMenuItem {
        let w = StatusBar.menuW
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 132))

        let head = trackedLabel("GAMMA", 10, .secondaryLabelColor, weight: .semibold, tracking: 2.2)
        head.frame = NSRect(x: 20, y: 104, width: 120, height: 14)
        v.addSubview(head)

        heroValue = NSTextField(labelWithString: "")
        heroValue.alignment = .right
        heroValue.frame = NSRect(x: w - 150, y: 88, width: 130, height: 32)
        setHero(1.0)
        v.addSubview(heroValue)

        slider = GammaSlider()
        slider.cell = CapsuleSliderCell()
        // configure range AFTER swapping the cell — a fresh cell defaults to 0...1,
        // which pins every gamma value ≥ 1 to the far right
        slider.minValue = Double(GAMMA_MIN)
        slider.maxValue = Double(GAMMA_MAX)
        slider.doubleValue = 1.0
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 50, width: w - 32, height: 32)
        v.addSubview(slider)

        // tick labels
        let ticks: [Float] = [0.8, 1.2, 1.6, 2.0, 2.4]
        let usable = w - 32
        for t in ticks {
            let frac = CGFloat((t - GAMMA_MIN) / (GAMMA_MAX - GAMMA_MIN))
            let l = makeLabel(String(format: "%.1f", t), 9.5, .tertiaryLabelColor)
            l.alignment = .center
            l.frame = NSRect(x: 16 + frac * usable - 14, y: 34, width: 28, height: 12)
            v.addSubview(l)
        }

        let i = NSMenuItem()
        i.view = v
        return i
    }

    // MARK: Preset capsule

    private func makePresetsItem() -> NSMenuItem {
        capsule = PresetCapsule(
            frame: NSRect(x: 16, y: 0, width: StatusBar.menuW - 32, height: 38),
            values: [("Default", 1.0), ("1.3", 1.3), ("1.6", 1.6), ("2.2", 2.2)]
        ) { [weak self] g in self?.applyGamma(g) }

        let v = NSView(frame: NSRect(x: 0, y: 0, width: StatusBar.menuW, height: 52))
        capsule.frame.origin = NSPoint(x: 16, y: 7)
        v.addSubview(capsule)
        let i = NSMenuItem()
        i.view = v
        return i
    }

    // MARK: Behavior

    private func setHero(_ g: Float) {
        let attr = NSMutableAttributedString(string: String(format: "%.2f", g), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: Palette.hero,
        ])
        attr.append(NSAttributedString(string: " γ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .baselineOffset: 1,
        ]))
        heroValue.attributedStringValue = attr
    }

    private func applyGamma(_ g: Float) {
        Gamma.set(g)
        slider.doubleValue = Double(g)
        setHero(g)
        capsule.highlight(g)
    }

    @objc func sliderChanged() {
        var g = Float(slider.doubleValue)
        // magnetic snap
        var snap: Float?
        for s in GAMMA_SNAPS where abs(g - s) < GAMMA_SNAP_THRESHOLD { snap = s }
        if let s = snap {
            g = s
            slider.doubleValue = Double(s)
            if lastSnapped != s {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                lastSnapped = s
            }
        } else {
            lastSnapped = nil
        }
        Gamma.set(g)
        setHero(g)
        capsule.highlight(g)
    }

    private func refreshToggles() {
        syncRow.toggle.state = sync.enabled ? .on : .off
        movieRow.toggle.state = movieMode.isOn ? .on : .off
        liveBadge.isHidden = !sync.enabled
    }

    @objc func toggleSync() {
        sync.enabled.toggle()
        if sync.enabled { sync.invalidate() }  // force a fresh write; stale hysteresis state would swallow it
        refreshToggles()
    }

    @objc func toggleMovie() {
        // stay on the main thread: MovieMode state is main-thread-confined,
        // and its DDC traffic serializes on DDC.queue internally
        movieMode.toggle()
        refreshToggles()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension StatusBar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let g = Gamma.get()
        slider.doubleValue = Double(g)
        setHero(g)
        capsule.highlight(g)
        refreshToggles()
    }
}

// MARK: - main

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // best effort on Quit/bootout; a hard kill is covered by the
        // persisted state file, which the next launch restores
        movieMode.restoreNowIfOn()
    }
}

/// True if a Luminos daemon process other than ourselves is running.
func daemonRunning() -> Bool {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "Luminos.app/Contents/MacOS/Luminos"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    // read to EOF before waitUntilExit (pipe discipline)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return false }
    let myPid = ProcessInfo.processInfo.processIdentifier
    let pids = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    return pids.contains { $0 != myPid }
}

let movieMode = MovieMode()
let sync = SyncEngine()

let args = CommandLine.arguments
sync.enabled = args.contains("--sync")

if args.contains("--test") {
    do {
        // suspend the daemon's sync loop so its writes can't clobber the probe
        FileManager.default.createFile(atPath: TEST_PAUSE_FLAG, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: TEST_PAUSE_FLAG) }
        Thread.sleep(forTimeInterval: 1.2)  // let any in-flight daemon write finish
        print("luminance:", DDC.getLuminance() ?? -1)
        print("contrast:", DDC.getContrast() ?? -1)
        print("builtin:", sync.builtin.value() ?? -1)
        // probe whether the monitor honors DDC luminance writes
        if let orig = DDC.getLuminance(), (0...100).contains(orig) {
            let probe = orig >= 90 ? orig - 10 : orig + 10
            DDC.setLuminance(probe)
            Thread.sleep(forTimeInterval: 1.5)
            let after = DDC.getLuminance()
            DDC.setLuminance(orig)  // restore
            if after == probe {
                print("ddc-write: ok (luminance writes accepted)")
            } else {
                print("ddc-write: REJECTED (monitor ignores luminance writes; read back \(after ?? -1), expected \(probe))")
            }
        } else {
            print("ddc-write: skipped (no valid luminance read)")
        }
    }
    exit(0)
}

if args.contains("--movie") {
    guard daemonRunning() else {
        FileHandle.standardError.write(Data("luminos: daemon is not running; movie flag not written\n".utf8))
        exit(1)
    }
    // timestamped so the daemon can drop a flag that outlives its window
    let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
    FileManager.default.createFile(atPath: MOVIE_FLAG, contents: Data(stamp.utf8))
    print("movie mode toggled")
    exit(0)
}

DDC.resolveDisplay()
movieMode.ingestPersistedState()
Gamma.loadAtLaunch()

// 1s tick: handles the --movie flag, pending restores, and the sync engine
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in sync.tick(movieMode: movieMode) }

// Status bar (accessory policy = no Dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate

// gamma survives sleep and replug: CoreGraphics drops transfer functions
// whenever displays sleep or re-enumerate, so push the value back
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Gamma.reapply() }
}
let screensObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Gamma.reapply() }
}
_ = wakeObserver
_ = screensObserver

// keep the C callback alive for the process lifetime
var displayConfigHandler: CGDisplayReconfigurationCallBack = { _, flags, _ in
    // react to mode changes and displays appearing/disappearing (sleep, replug)
    guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
           || flags.contains(.removeFlag) || flags.contains(.enabledFlag) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Gamma.reapply() }
}
CGDisplayRegisterReconfigurationCallback(displayConfigHandler, nil)

let statusBar = StatusBar()
_ = statusBar

NSLog("luminos: started (sync=\(sync.enabled))")
app.run()

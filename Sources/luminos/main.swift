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
let DISPLAY_ARG = "2"              // m1ddc display index of the external monitor
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
    @discardableResult
    static func run(_ args: [String]) -> String? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: M1DDC)
        p.arguments = ["display", DISPLAY_ARG] + args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            return s?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    static func getLuminance() -> Int? { run(["get", "luminance"]).flatMap(Int.init) }
    static func getContrast() -> Int? { run(["get", "contrast"]).flatMap(Int.init) }
    @discardableResult
    static func setLuminance(_ v: Int) -> String? { run(["set", "luminance", "\(max(0, min(100, v)))"]) }
    static func setContrast(_ v: Int) { run(["set", "contrast", "\(max(0, min(100, v)))"]) }
}

// MARK: - Movie mode (DDC backlight boost)

final class MovieMode {
    private var saved: (lum: Int, con: Int)?
    var isOn: Bool { saved != nil }

    func toggle() {
        if let s = saved {
            DDC.setLuminance(s.lum)
            DDC.setContrast(s.con)
            saved = nil
            NSLog("luminos: movie mode off (restored \(s.lum)/\(s.con))")
        } else {
            guard let l = DDC.getLuminance(), let c = DDC.getContrast(),
                  (0...100).contains(l), (0...100).contains(c) else {
                NSLog("luminos: movie mode on failed (bad DDC read)")
                return
            }
            saved = (l, c)
            DDC.setLuminance(MOVIE_LUMINANCE)
            DDC.setContrast(MOVIE_CONTRAST)
            NSLog("luminos: movie mode on (saved \(l)/\(c))")
        }
    }
}

// MARK: - Built-in display brightness

typealias DSGetBrightnessValue = @convention(c) (UnsafeMutablePointer<Float>) -> Int32

final class BuiltinBrightness {
    private var getFn: DSGetBrightnessValue?
    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let h = dlopen(path, RTLD_LAZY),
           let sym = dlsym(h, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: DSGetBrightnessValue.self)
        }
    }
    /// Primary source on Apple Silicon: parse corebrightnessdiag status-info,
    /// taking the Brightness real inside the DisplayBrightness dict of the
    /// built-in display's section. (IOKit's IODisplayGetFloatParameter returns
    /// a frozen registry value on M1 — do not use it.)
    private func coreBrightnessValue() -> Float? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/corebrightnessdiag")
        p.arguments = ["status-info"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard let _ = try? p.run() else { return nil }
        p.waitUntilExit()
        guard let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let re = try? NSRegularExpression(
                  pattern: #"<key>DisplayBrightness</key>\s*<dict>\s*<key>Brightness</key>\s*<real>([0-9.]+)</real>"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Float(s[r])
    }

    func value() -> Float? {
        if let f = getFn {
            var v: Float = -1
            if f(&v) == 0, v >= 0 { return v }
        }
        return coreBrightnessValue()
    }
}

// MARK: - Sync engine

final class SyncEngine {
    let builtin = BuiltinBrightness()
    var enabled = false
    var lastSent: Int?
    var onToggle: (() -> Void)?

    /// Poll once per second; call from main run loop timer.
    func tick(movieMode: MovieMode) {
        // movie mode toggle requested via `luminos --movie`
        let flag = "/tmp/luminos_movie_toggle"
        if FileManager.default.fileExists(atPath: flag) {
            try? FileManager.default.removeItem(atPath: flag)
            movieMode.toggle()
        }
        guard enabled, !movieMode.isOn else { return }
        guard let b = builtin.value(), b >= 0 else { return }
        let mapped = SYNC_MIN + Int((Float(SYNC_MAX - SYNC_MIN) * b).rounded())
        if let last = lastSent, abs(mapped - last) < SYNC_HYSTERESIS { return }
        lastSent = mapped
        DDC.setLuminance(mapped)
        NSLog("luminos: sync set luminance=\(mapped) (builtin=\(b))")
    }
}

// MARK: - Gamma control (CoreGraphics transfer formula, per-display)

enum Gamma {
    static let displayID = CGDirectDisplayID(2)  // Mi Monitor

    static func get() -> Float {
        var rmin: Float = 0, rmax: Float = 1, rg: Float = 1
        var gmin: Float = 0, gmax: Float = 1, gg: Float = 1
        var bmin: Float = 0, bmax: Float = 1, bg: Float = 1
        CGGetDisplayTransferByFormula(displayID, &rmin, &rmax, &rg, &gmin, &gmax, &gg, &bmin, &bmax, &bg)
        return gg
    }

    static func set(_ g: Float) {
        let v = max(GAMMA_MIN, min(GAMMA_MAX, g))
        CGSetDisplayTransferByFormula(displayID, 0, 1, v, 0, 1, v, 0, 1, v)
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

final class GammaSlider: NSSlider {
    var onSnap: ((Float) -> Void)?
    private var snappedValue: Float?

    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }
}

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

        sync.onToggle = { [weak self] in self?.refreshToggles() }
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

        slider = GammaSlider(value: 1.0, minValue: Double(GAMMA_MIN), maxValue: Double(GAMMA_MAX),
                             target: self, action: #selector(sliderChanged))
        slider.cell = CapsuleSliderCell()
        slider.cell?.controlSize = .regular
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
        refreshToggles()
    }

    @objc func toggleMovie() {
        DispatchQueue.global().async {
            movieMode.toggle()
            DispatchQueue.main.async { self.refreshToggles() }
        }
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

let movieMode = MovieMode()
let sync = SyncEngine()

let args = CommandLine.arguments
sync.enabled = args.contains("--sync")

if args.contains("--test") {
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
    exit(0)
}

if args.contains("--movie") {
    // signal the running daemon to toggle movie mode
    FileManager.default.createFile(atPath: "/tmp/luminos_movie_toggle", contents: nil)
    print("movie mode toggled")
    exit(0)
}

// 1s tick: handles the --movie flag and, when enabled, the sync engine
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in sync.tick(movieMode: movieMode) }

// Status bar (accessory policy = no Dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusBar = StatusBar()
_ = statusBar

NSLog("luminos: started (sync=\(sync.enabled))")
app.run()

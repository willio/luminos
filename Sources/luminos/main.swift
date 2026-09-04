//
//  luminos — DDC brightness companion for external monitors on Apple Silicon
//
//  - F14/F15 (system brightness keys): pass through, mirror ±STEP to the
//    external monitor via DDC (m1ddc).
//  - F17: toggle "movie mode" (hardware backlight boost, restores on off).
//  - --sync: keep the external monitor mapped to the built-in display's
//    brightness (polls once per second).
//
//  Requires: Accessibility permission (for the CGEvent tap), m1ddc installed.
//

import Cocoa

// MARK: - Config

let M1DDC = "/opt/homebrew/bin/m1ddc"
let DISPLAY_ARG = "2"              // m1ddc display index of the external monitor
let STEP = 8                       // DDC luminance step per key press
let SYNC_MIN = 10                  // DDC luminance floor when syncing
let SYNC_MAX = 100
let SYNC_HYSTERESIS = 2            // ignore built-in changes smaller than this (mapped units)
let MOVIE_LUMINANCE = 100          // movie mode targets
let MOVIE_CONTRAST = 85

let KEYCODE_F17: Int64 = 64        // regular key event keycodes

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
    static func changeLuminance(_ d: Int) { run(["chg", "luminance", d > 0 ? "+\(d)" : "\(d)"]) }
}

// MARK: - Movie mode (DDC backlight boost; no gamma tables)

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

// MARK: - Built-in display brightness (private DisplayServices API)

typealias DSGetBrightness = @convention(c) (Int32) -> Int32
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

    /// Poll once per second; call from main run loop timer.
    func tick(movieMode: MovieMode) {
        // movie mode toggle requested via `luminos --movie` (no Accessibility needed)
        let flag = "/tmp/luminos_movie_toggle"
        if FileManager.default.fileExists(atPath: flag) {
            try? FileManager.default.removeItem(atPath: flag)
            movieMode.toggle()
        }
        guard enabled, !movieMode.isOn else { return }
        guard let b = builtin.value(), b >= 0 else { NSLog("luminos: sync tick, builtin read failed"); return }
        let mapped = SYNC_MIN + Int((Float(SYNC_MAX - SYNC_MIN) * b).rounded())
        if let last = lastSent, abs(mapped - last) < SYNC_HYSTERESIS { return }
        lastSent = mapped
        let r = DDC.setLuminance(mapped)
        NSLog("luminos: sync set luminance=\(mapped) (builtin=\(b)) result=\(r ?? "nil")")
    }
}

// MARK: - Event tap

let movieMode = MovieMode()
let sync = SyncEngine()

let args = CommandLine.arguments
sync.enabled = args.contains("--sync")

func handleSystemDefined(_ event: CGEvent) -> Unmanaged<CGEvent>? {
    guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let key = (ns.data1 & 0xFFFF_0000) >> 16
    let keyFlags = ns.data1 & 0xFF00
    guard keyFlags == 0x0A00 else { return Unmanaged.passUnretained(event) } // key down only
    // NX_KEYTYPE_BRIGHTNESS_UP = 2, BRIGHTNESS_DOWN = 3
    if key == 2 {
        DispatchQueue.global().async { DDC.changeLuminance(STEP) }
    } else if key == 3 {
        DispatchQueue.global().async { DDC.changeLuminance(-STEP) }
    }
    return Unmanaged.passUnretained(event)  // let the system adjust the built-in too
}

func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == 14 { // NX_SYSDEFINED (media keys)
        if let ns = NSEvent(cgEvent: event) {
            NSLog("luminos: sysdef subtype=\(ns.subtype.rawValue) data1=\(String(ns.data1, radix: 16))")
        } else {
            NSLog("luminos: sysdef event, NSEvent conversion failed")
        }
        return handleSystemDefined(event)
    }
    if type == .keyDown {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        NSLog("luminos: keyDown keycode=\(kc)")
        if kc == KEYCODE_F17 {
            DispatchQueue.global().async { movieMode.toggle() }
            return nil // consume F17
        }
    }
    return Unmanaged.passUnretained(event)
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
        let v = max(0.5, min(3.5, g))
        CGSetDisplayTransferByFormula(displayID, 0, 1, v, 0, 1, v, 0, 1, v)
    }

    static func reset() { set(1.0) }
}

// MARK: - Status bar UI

final class StatusBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let slider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 3.5, target: nil, action: nil)
    let syncItem = NSMenuItem(title: "Sync with built-in display", action: #selector(toggleSync), keyEquivalent: "")
    let movieItem = NSMenuItem(title: "Movie Mode (backlight boost)", action: #selector(toggleMovie), keyEquivalent: "")
    let gammaLabel = NSMenuItem(title: "Gamma (drag to adjust)", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Luminos")
        }
        slider.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true

        let menu = NSMenu()
        gammaLabel.isEnabled = false
        menu.addItem(gammaLabel)
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)
        let resetItem = NSMenuItem(title: "Reset Gamma", action: #selector(resetGamma), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(.separator())
        syncItem.target = self
        syncItem.state = sync.enabled ? .on : .off
        menu.addItem(syncItem)
        movieItem.target = self
        menu.addItem(movieItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luminos", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
    }

    @objc func sliderChanged() {
        let g = Float(slider.doubleValue)
        Gamma.set(g)
        gammaLabel.title = String(format: "Gamma: %.2f (drag to adjust)", g)
    }

    @objc func resetGamma() {
        Gamma.reset()
        slider.doubleValue = 1.0
        gammaLabel.title = "Gamma: 1.00 (drag to adjust)"
    }

    @objc func toggleSync() {
        sync.enabled.toggle()
        syncItem.state = sync.enabled ? .on : .off
    }

    @objc func toggleMovie() {
        DispatchQueue.global().async { movieMode.toggle() }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension StatusBar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let g = Gamma.get()
        slider.doubleValue = Double(g)
        gammaLabel.title = String(format: "Gamma: %.2f (drag to adjust)", g)
        movieItem.state = movieMode.isOn ? .on : .off
    }
}

// MARK: - main

var gTap: CFMachPort?

if CommandLine.arguments.contains("--test") {
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

if CommandLine.arguments.contains("--movie") {
    // signal the running daemon to toggle movie mode
    FileManager.default.createFile(atPath: "/tmp/luminos_movie_toggle", contents: nil)
    print("movie mode toggled")
    exit(0)
}

let mask = (1 << CGEventType.keyDown.rawValue) | (1 << 14 /* NX_SYSDEFINED */)
var tapStarted = false

func tryStartTap() -> Bool {
    if tapStarted { return true }
    guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary),
          let tap = CGEvent.tapCreate(
              tap: .cgSessionEventTap,
              place: .headInsertEventTap,
              options: .defaultTap,
              eventsOfInterest: CGEventMask(mask),
              callback: eventCallback,
              userInfo: nil
          ) else { return false }
    gTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapStarted = true
    NSLog("luminos: event tap started (keys enabled)")
    return true
}

if !tryStartTap() {
    NSLog("luminos: no Accessibility permission — running sync-only (keys disabled)")
    // re-check every 30s so a later grant activates the keys without a restart
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in _ = tryStartTap() }
}

if sync.enabled {
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in sync.tick(movieMode: movieMode) }
}

// Status bar (needs an NSApplication; accessory policy = no Dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusBar = StatusBar()
_ = statusBar

NSLog("luminos: started (sync=\(sync.enabled))")
app.run()

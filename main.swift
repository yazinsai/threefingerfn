// Rest three fingers on the trackpad (no click needed) for >0.5s to hold Fn; lift to release Fn,
// then press Return 0.5s later (time for push-to-talk dictation to finish transcribing).
// Press Escape while holding (or before Return fires) to cancel: Escape goes to the
// dictation app, Fn is released, and no Return is sent.
// Shorter three-finger touches and swipes are untouched; clicks pass through as normal.
// Usage: ./threefingerfn [holdDelay] [enterDelay]   e.g. ./threefingerfn 0.5 0.5   (enterDelay < 0 disables Return)
import Cocoa
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
let holdDelay: TimeInterval = args.count > 0 ? args[0] : 0.5
let enterDelay: TimeInterval = args.count > 1 ? args[1] : 0.5
let marker: Int64 = 0x46_4E_48_4C // tags events we post so the tap ignores them
let escapeKey: Int64 = 53

// MARK: finger count via private MultitouchSupport framework
typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
typealias CreateList = @convention(c) () -> Unmanaged<CFArray>
typealias Register = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
let mtCreateList = unsafeBitCast(dlsym(mt, "MTDeviceCreateList"), to: CreateList.self)
let mtRegister = unsafeBitCast(dlsym(mt, "MTRegisterContactFrameCallback"), to: Register.self)
let mtStart = unsafeBitCast(dlsym(mt, "MTDeviceStart"), to: Start.self)
typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
let mtGetID = unsafeBitCast(dlsym(mt, "MTDeviceGetDeviceID"), to: GetID.self)

// Runs on a MultitouchSupport thread; hop to the main thread before touching state.
let contactCallback: MTContactCallback = { _, _, count, _, _ in
    DispatchQueue.main.async { handleFingers(count) }
    return 0
}
var attachedIDs = Set<UInt64>()  // MTDeviceCreateList returns fresh objects each call, so dedupe by device ID
func attachTrackpads() {
    let list = mtCreateList().takeRetainedValue() as [AnyObject]
    for d in list {
        let p = Unmanaged.passUnretained(d).toOpaque()
        var id: UInt64 = 0
        _ = mtGetID(p, &id)
        if !attachedIDs.insert(id).inserted { continue }
        _ = Unmanaged.passRetained(d) // keep alive
        mtRegister(p, contactCallback)
        mtStart(p, 0)
    }
}

// MARK: state
// pending = three fingers are down, waiting for holdDelay.
// cancelled = Escape was pressed while recording; stay inert until the fingers lift.
enum State { case idle, pending, fnHeld, cancelled }
var state = State.idle
var lastCount: Int32 = 0
var timer: Timer?
var enterTimer: Timer?
let src = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent) {
    e.setIntegerValueField(.eventSourceUserData, value: marker)
    e.post(tap: .cghidEventTap)
}
func sendFn(_ down: Bool) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    post(e)
    print(down ? "Fn down" : "Fn up"); fflush(stdout)
}
func sendReturn() {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down) else { return }
        e.flags = []
        post(e)
    }
    print("Return"); fflush(stdout)
}
func releaseFn() {
    state = .idle
    sendFn(false)
    guard enterDelay >= 0 else { return }
    enterTimer = Timer.scheduledTimer(withTimeInterval: enterDelay, repeats: false) { _ in
        enterTimer = nil
        sendReturn()
    }
}
func cancelRecording() {
    state = .cancelled
    print("Cancelled"); fflush(stdout)
    // Let the Escape reach the dictation app first so it cancels instead of finishing, then release Fn.
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in sendFn(false) }
}

// Touch-driven: three fingers resting for holdDelay hold Fn; lifting any finger releases it.
func handleFingers(_ count: Int32) {
    guard count != lastCount else { return }
    lastCount = count
    if count == 3 {
        guard case .idle = state else { return }
        enterTimer?.invalidate(); enterTimer = nil // a new touch before Return fires cancels it
        state = .pending
        timer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { _ in
            if case .pending = state, lastCount == 3 { state = .fnHeld; sendFn(true) }
        }
    } else {
        timer?.invalidate(); timer = nil
        switch state {
        case .fnHeld: releaseFn()
        case .pending, .cancelled: state = .idle
        case .idle: break
        }
    }
}

var tap: CFMachPort?
let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown]
let upTypes: Set<CGEventType> = [.leftMouseUp, .rightMouseUp]
let dragTypes: Set<CGEventType> = [.leftMouseDragged, .rightMouseDragged]

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }

    // Escape: cancel the recording, or the pending Return if you already let go.
    if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == escapeKey {
        if case .fnHeld = state {
            event.flags.remove(.maskSecondaryFn) // deliver it as a plain Escape
            cancelRecording()
        } else if let t = enterTimer {
            t.invalidate(); enterTimer = nil
            print("Return cancelled"); fflush(stdout)
        }
        return Unmanaged.passUnretained(event) // the dictation app still sees Escape
    }
    if type == .keyDown || type == .keyUp { return Unmanaged.passUnretained(event) }

    // While recording (or after Escape), a harder press must not click through.
    switch state {
    case .fnHeld, .cancelled:
        if downTypes.contains(type) || dragTypes.contains(type) { return nil }
    case .idle, .pending: break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: main
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) {
    print("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)..."); fflush(stdout)
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 2) }
}
attachTrackpads()
let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged, .keyDown]
    .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback, userInfo: nil) else {
    print("Could not create event tap (missing Accessibility / Input Monitoring permission)."); exit(1)
}
tap = t
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
CGEvent.tapEnable(tap: t, enable: true)
// pick up trackpads connected later (e.g. Magic Trackpad over Bluetooth)
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in attachTrackpads() }
signal(SIGINT) { _ in if case .fnHeld = state { sendFn(false) }; exit(0) }
print("threefingerfn running: rest three fingers for \(holdDelay)s to hold Fn; Return \(enterDelay)s after release; Escape cancels.")
CFRunLoopRun()

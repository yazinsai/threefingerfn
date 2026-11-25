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
let fingerCount: Int32 = args.count > 2 ? Int32(args[2]) : 3
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
typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32
let mtStop = unsafeBitCast(dlsym(mt, "MTDeviceStop"), to: Stop.self)
let mtUnregister = unsafeBitCast(dlsym(mt, "MTUnregisterContactFrameCallback"), to: Register.self)

// Runs on a MultitouchSupport thread; hop to the main thread before touching state.
let contactCallback: MTContactCallback = { _, _, count, _, _ in
    DispatchQueue.main.async { handleFingers(count) }
    return 0
}
// A reconnected trackpad (Bluetooth off/on, wake) keeps its device ID, but the old device object
// stops delivering frames. So drop every old object and attach fresh ones each time.
var devices: [UnsafeMutableRawPointer] = []  // each one retained by us
func attachTrackpads() {
    for p in devices {
        mtUnregister(p, contactCallback)
        _ = mtStop(p)
        Unmanaged<AnyObject>.fromOpaque(p).release()
    }
    devices = (mtCreateList().takeRetainedValue() as [AnyObject]).map { d in
        let p = Unmanaged.passRetained(d).toOpaque()
        mtRegister(p, contactCallback)
        mtStart(p, 0)
        return p
    }
    print("Attached \(devices.count) trackpad(s)"); fflush(stdout)
}
var reattachPending = false
func scheduleReattach(_ reason: String) {
    guard !reattachPending else { return }
    reattachPending = true
    // Wait so a device that just appeared is ready and a burst of notifications becomes one reattach.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        reattachPending = false
        print("Reattaching trackpads (\(reason))"); fflush(stdout)
        attachTrackpads()
        handleFingers(0) // frames from the old objects may have stopped mid-touch; reset to idle
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

// Touch-driven: the set number of fingers resting for holdDelay holds Fn; only lifting every finger releases it.
func handleFingers(_ count: Int32) {
    guard count != lastCount else { return }
    lastCount = count
    if count == fingerCount {
        guard case .idle = state else { return }
        enterTimer?.invalidate(); enterTimer = nil // a new touch before Return fires cancels it
        state = .pending
        timer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { _ in
            if case .pending = state, lastCount == fingerCount { state = .fnHeld; sendFn(true) }
        }
    } else {
        // Before Fn goes down, any change cancels (swipes stay untouched). After that, only a full
        // lift ends the hold, so shifting fingers mid-dictation does not stop it.
        switch state {
        case .pending: timer?.invalidate(); timer = nil; state = .idle
        case .fnHeld: if count == 0 { releaseFn() }
        case .cancelled: if count == 0 { state = .idle }
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
// Reattach when a trackpad appears (Magic Trackpad connects or reconnects) and after wake.
let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
var addedIter: io_iterator_t = 0
func drain(_ iter: io_iterator_t) { while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) } }
IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                 { _, iter in drain(iter); scheduleReattach("trackpad added") }, nil, &addedIter)
drain(addedIter) // existing devices are attached already; draining arms the notification
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    scheduleReattach("wake")
}
signal(SIGINT) { _ in if case .fnHeld = state { sendFn(false) }; exit(0) }
print("threefingerfn running: rest \(fingerCount) fingers for \(holdDelay)s to hold Fn; Return \(enterDelay)s after release; Escape cancels."); fflush(stdout)
CFRunLoopRun()

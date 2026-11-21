import AppKit
import CoreGraphics
import HereforthCore
import IOKit.pwr_mgt
import SwiftUI

enum AwakeMode: String, CaseIterable, Identifiable {
    case system
    case display

    var id: Self { self }
    var title: String { self == .system ? "System" : "System and displays" }
    var assertionType: CFString {
        (self == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString
    }
}

enum AwakeDuration: Int, CaseIterable, Identifiable {
    case quarterHour = 15
    case halfHour = 30
    case hour = 60
    case twoHours = 120
    case indefinite = 0

    var id: Self { self }
    var seconds: Int { rawValue * 60 }
    var title: String {
        switch self {
        case .quarterHour: "15 minutes"
        case .halfHour: "30 minutes"
        case .hour: "1 hour"
        case .twoHours: "2 hours"
        case .indefinite: "Until stopped"
        }
    }
}

@MainActor
final class KeepAwake: ObservableObject {
    @Published var preferredMode: AwakeMode = .system
    @Published var preferredDuration: AwakeDuration = .hour
    @Published private(set) var mode: AwakeMode?
    @Published private(set) var endsAt: Date?
    @Published private(set) var pointerEnabled = false
    @Published private(set) var intervalSeconds = 60
    @Published private(set) var pointerPermissionRequired = false
    @Published private(set) var problem: String?

    private var assertion: IOPMAssertionID?
    private var deadline: ContinuousClock.Instant?
    private var expiration: Task<Void, Never>?
    private var pointerTimer: Task<Void, Never>?
    private var screenSaverActive = false
    private var screenLocked = false
    private var systemSleeping = false
    private var previousStep: CGFloat = -1
    private var statusStore: Store?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let pointerSource = CGEventSource(stateID: .privateState)

    init() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screensaver.didstart") { $0.screenSaverActive = true }
        observe(distributed, "com.apple.screensaver.didstop") { $0.screenSaverActive = false }
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.systemSleeping = false }
        publishStatus()
    }

    deinit {
        expiration?.cancel()
        pointerTimer?.cancel()
        if let assertion { IOPMAssertionRelease(assertion) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    var status: String {
        guard let mode else { return "Keep Awake is off" }
        if let endsAt {
            return "\(mode.title) awake until \(endsAt.formatted(date: .omitted, time: .shortened))"
        }
        return "\(mode.title) awake until stopped"
    }

    func start(_ mode: AwakeMode, seconds: Int) {
        guard assertion == nil, seconds >= 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            mode.assertionType, "Hereforth Keep Awake" as CFString,
            nil, nil, nil, TimeInterval(seconds),
            kIOPMAssertionTimeoutActionRelease as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            problem = "macOS couldn’t start Keep Awake (\(result))."
            return
        }
        problem = nil
        assertion = id
        self.mode = mode
        endsAt = seconds == 0 ? nil : .now.addingTimeInterval(TimeInterval(seconds))
        if seconds > 0 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            self.deadline = deadline
            expiration = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                if !Task.isCancelled { self?.stop() }
            }
        }
        schedulePointer()
        publishStatus()
    }

    func stop() {
        expiration?.cancel()
        expiration = nil
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
        deadline = nil
        mode = nil
        endsAt = nil
        schedulePointer()
        publishStatus()
    }

    func setPointerEnabled(_ enabled: Bool) {
        if enabled && !CGPreflightPostEventAccess() {
            pointerPermissionRequired = !CGRequestPostEventAccess()
            guard !pointerPermissionRequired else {
                publishStatus()
                return
            }
        }
        pointerPermissionRequired = false
        pointerEnabled = enabled
        schedulePointer()
        publishStatus()
    }

    func setPointerInterval(_ seconds: Int) {
        intervalSeconds = seconds
        schedulePointer()
        publishStatus()
    }

    private func publishStatus() {
        if statusStore == nil { statusStore = try? Store() }
        try? statusStore?.setKeepAwakeStatus(
            mode: mode?.rawValue,
            endsAt: endsAt,
            intervalSeconds: intervalSeconds,
            pointerState: pointerPermissionRequired ? "permissionRequired" : pointerEnabled ? "enabled" : "off"
        )
    }

    private func observe(_ center: NotificationCenter, _ name: String, action: @escaping (KeepAwake) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }

    private func schedulePointer() {
        pointerTimer?.cancel()
        pointerTimer = nil
        guard mode != nil, pointerEnabled else { return }
        let seconds = intervalSeconds
        pointerTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled else { return }
                if self?.movePointerIfIdle() != true { return }
            }
        }
    }

    private func movePointerIfIdle() -> Bool {
        if let deadline, ContinuousClock.now >= deadline {
            stop()
            return false
        }
        guard CGPreflightPostEventAccess() else {
            pointerEnabled = false
            pointerPermissionRequired = true
            publishStatus()
            return false
        }
        guard !systemSleeping, !screenLocked, !screenSaverActive,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              let current = CGEvent(source: nil)?.location,
              let display = display(at: current), CGDisplayIsAsleep(display) == 0,
              pointerIdle, let pointerSource
        else { return true }

        let bounds = CGDisplayBounds(display)
        for step in [-previousStep, previousStep] {
            let destination = CGPoint(x: current.x + step, y: current.y)
            if bounds.contains(destination) {
                CGEvent(mouseEventSource: pointerSource, mouseType: .mouseMoved,
                        mouseCursorPosition: destination, mouseButton: .left)?.post(tap: .cghidEventTap)
                previousStep = step
                break
            }
        }
        return true
    }

    private var pointerIdle: Bool {
        let events: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                     .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown,
                                     .otherMouseUp, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty &&
            events.allSatisfy { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= 15 } &&
            (0...4).allSatisfy {
                guard let button = CGMouseButton(rawValue: UInt32($0)) else { return true }
                return !CGEventSource.buttonState(.hidSystemState, button: button)
            }
    }

    private func display(at point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return display
    }
}

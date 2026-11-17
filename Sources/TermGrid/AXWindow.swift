import ApplicationServices
import CoreGraphics
import GridCore

struct AXWindow: @unchecked Sendable, Hashable {
    static let messagingTimeout: Float = 0.25

    let element: AXUIElement
    let pid: pid_t

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(CFHash(element))
    }

    var title: String? {
        try? copyValue(kAXTitleAttribute).get() as? String
    }

    var role: String? {
        try? copyValue(kAXRoleAttribute).get() as? String
    }

    var subrole: String? {
        try? copyValue(kAXSubroleAttribute).get() as? String
    }

    var frame: CGRect? {
        try? readFrame().get()
    }

    var isPositionSettable: Bool {
        (try? settable(kAXPositionAttribute).get()) ?? false
    }

    var isSizeSettable: Bool {
        (try? settable(kAXSizeAttribute).get()) ?? false
    }

    var isMinimized: Bool {
        (try? copyValue(kAXMinimizedAttribute).get() as? Bool) ?? false
    }

    var isFullScreen: Bool {
        (try? copyValue("AXFullScreen").get() as? Bool) ?? false
    }

    @discardableResult
    func raise() -> AXError {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func failure(_ error: AXError) -> AccessFailure? {
        switch error {
        case .success:
            return nil
        case .cannotComplete:
            return .timeout
        case .invalidUIElement:
            return .invalidElement
        default:
            return .failed
        }
    }

    private func copyValue(_ attribute: String) -> Result<CFTypeRef, AccessFailure> {
        var value: CFTypeRef?
        if let failure = Self.failure(AXUIElementCopyAttributeValue(element, attribute as CFString, &value)) {
            return .failure(failure)
        }
        guard let value else {
            return .failure(.failed)
        }
        return .success(value)
    }

    private func settable(_ attribute: String) -> Result<Bool, AccessFailure> {
        var settable = DarwinBoolean(false)
        if let failure = Self.failure(AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)) {
            return .failure(failure)
        }
        return .success(settable.boolValue)
    }

    private func axValue(_ attribute: String) -> Result<AXValue, AccessFailure> {
        copyValue(attribute).flatMap { raw in
            CFGetTypeID(raw) == AXValueGetTypeID() ? .success(raw as! AXValue) : .failure(.failed)
        }
    }

    private func position() -> Result<CGPoint, AccessFailure> {
        axValue(kAXPositionAttribute).flatMap { raw in
            var point = CGPoint.zero
            return AXValueGetValue(raw, .cgPoint, &point) ? .success(point) : .failure(.failed)
        }
    }

    private func size() -> Result<CGSize, AccessFailure> {
        axValue(kAXSizeAttribute).flatMap { raw in
            var size = CGSize.zero
            return AXValueGetValue(raw, .cgSize, &size) ? .success(size) : .failure(.failed)
        }
    }
}

extension AXWindow: WindowAccess {
    func querySizeSettable() -> Result<Bool, AccessFailure> {
        settable(kAXSizeAttribute)
    }

    func writeSize(_ size: CGSize) -> AccessFailure? {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else {
            return .failed
        }
        return Self.failure(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue))
    }

    func writePosition(_ origin: CGPoint) -> AccessFailure? {
        var value = origin
        guard let axValue = AXValueCreate(.cgPoint, &value) else {
            return .failed
        }
        return Self.failure(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue))
    }

    func readFrame() -> Result<CGRect, AccessFailure> {
        position().flatMap { origin in
            size().map { size in
                CGRect(origin: origin, size: size)
            }
        }
    }
}

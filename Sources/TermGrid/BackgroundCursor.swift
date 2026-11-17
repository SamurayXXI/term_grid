import Darwin
import Foundation
import os

private let cursorLogger = Logger(subsystem: "local.termgrid", category: "ui")

enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private(set) static var isEnabled = false

    static func enable() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(handle, "CGSDefaultConnectionForThread") ?? dlsym(handle, "_CGSDefaultConnection"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty")
        else {
            cursorLogger.notice("background cursor unavailable")
            return
        }
        let defaultConnection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)
        let setProperty = unsafeBitCast(propertySymbol, to: SetConnectionProperty.self)
        let connection = defaultConnection()
        let result = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        isEnabled = result == 0
        cursorLogger.notice("background cursor enabled=\(isEnabled) result=\(result)")
    }
}

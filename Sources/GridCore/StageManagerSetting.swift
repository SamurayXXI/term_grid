import Foundation

public enum StageManagerSetting {
    public static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        default:
            return false
        }
    }
}

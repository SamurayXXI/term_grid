import Foundation
import Testing
@testable import GridCore

@Suite struct StageManagerTests {
    @Test func missingKeyIsOff() {
        #expect(!StageManagerSetting.isEnabled(nil))
    }

    @Test func boolValues() {
        #expect(StageManagerSetting.isEnabled(true))
        #expect(!StageManagerSetting.isEnabled(false))
    }

    @Test func numberValues() {
        #expect(StageManagerSetting.isEnabled(NSNumber(value: 1)))
        #expect(!StageManagerSetting.isEnabled(NSNumber(value: 0)))
    }

    @Test func otherTypesAreOff() {
        #expect(!StageManagerSetting.isEnabled("1"))
        #expect(!StageManagerSetting.isEnabled([1]))
    }
}

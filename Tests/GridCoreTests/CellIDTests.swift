import Testing
@testable import GridCore

@Test func cellIDEqualityFollowsRawValue() {
    #expect(CellID(1) == CellID(1))
    #expect(CellID(1) != CellID(2))
}

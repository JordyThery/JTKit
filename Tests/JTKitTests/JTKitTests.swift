import Testing
@testable import JTKit

@Test func versionIsSet() {
    #expect(!JTKit.version.isEmpty)
}

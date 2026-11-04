import Testing
@testable import SpatialAudioCore

/// Step 0 smoke test: proves the test target builds and runs. Not a logic test.
@Suite struct SmokeTests {
    @Test func moduleLinks() {
        #expect(SpatialAudioCore.moduleName == "SpatialAudioCore")
    }
}

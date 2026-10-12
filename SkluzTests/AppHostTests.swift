import Testing
@testable import Skluz

struct AppHostTests {

    /// The test host is the real app: if this detection breaks, every test
    /// run starts the user's autoStart tunnels and leaves them orphaned.
    @MainActor @Test func appDetectsItIsHostingTests() {
        #expect(AppDelegate.isHostingTests)
    }
}

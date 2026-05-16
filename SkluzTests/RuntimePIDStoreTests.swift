import Foundation
import Testing
@testable import Skluz

struct RuntimePIDStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzPID-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("runtime.json", isDirectory: false)
    }

    @Test func roundTripsPIDMap() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuntimePIDStore(url: url)
        let a = UUID(), b = UUID()
        store.save([a: 4242, b: 9001])

        let reloaded = RuntimePIDStore(url: url).load()
        #expect(reloaded == [a: 4242, b: 9001])
    }

    @Test func missingFileLoadsEmpty() {
        let store = RuntimePIDStore(url: tempURL())
        #expect(store.load().isEmpty)
    }

    @Test func saveOverwritesPreviousContent() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuntimePIDStore(url: url)
        let id = UUID()
        store.save([id: 1])
        store.save([id: 2])
        #expect(store.load() == [id: 2])
    }
}

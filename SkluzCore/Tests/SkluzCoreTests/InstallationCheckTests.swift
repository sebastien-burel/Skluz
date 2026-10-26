import Foundation
import Testing
import Darwin
@testable import SkluzCore

/// Builds the bundle skeleton launchd relies on, owned by the current user,
/// who stands in for root.
struct InstallationCheckTests {

    private func makeBundle() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzInstall-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Skluz.app", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appending(path: "Contents/Library/LaunchDaemons"), withIntermediateDirectories: true)
        for (file, mode) in [("Contents/MacOS/skluzd", 0o755), ("Contents/Library/LaunchDaemons/net.haruni.skluzd.plist", 0o644)] {
            fm.createFile(atPath: bundle.appending(path: file).path(percentEncoded: false), contents: Data(),
                          attributes: [.posixPermissions: mode])
        }
        for dir in ["", "Contents", "Contents/MacOS", "Contents/Library", "Contents/Library/LaunchDaemons"] {
            chmod((dir.isEmpty ? bundle : bundle.appending(path: dir)).path(percentEncoded: false), 0o755)
        }
        return bundle
    }

    private func cleanup(_ bundle: URL) {
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    @Test func ownedAndReadOnlyBundleIsAccepted() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        #expect(InstallationCheck.firstProblem(bundle: bundle, owner: getuid()) == nil)
    }

    @Test func userOwnedBundleIsRefusedForRoot() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        let problem = try #require(InstallationCheck.firstProblem(bundle: bundle, owner: 0))
        #expect(problem.issue == .wrongOwner(uid: getuid()))
        #expect(problem.fixCommand.hasPrefix("sudo chown -R root:wheel"))
    }

    @Test func groupWritableDaemonIsRefused() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        let daemon = bundle.appending(path: "Contents/MacOS/skluzd").path(percentEncoded: false)
        chmod(daemon, 0o775)

        let problem = try #require(InstallationCheck.firstProblem(bundle: bundle, owner: getuid()))
        #expect(problem.path.hasSuffix("Contents/MacOS/skluzd"))
        #expect(problem.issue == .writableByOthers(mode: 0o775))
    }

    @Test func symlinkedPlistIsRefused() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        let plist = bundle.appending(path: "Contents/Library/LaunchDaemons/net.haruni.skluzd.plist")
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.createSymbolicLink(atPath: plist.path(percentEncoded: false), withDestinationPath: "/tmp/x")

        #expect(InstallationCheck.firstProblem(bundle: bundle, owner: getuid())?.issue == .symbolicLink)
    }

    @Test func missingDaemonIsReported() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        try FileManager.default.removeItem(at: bundle.appending(path: "Contents/MacOS/skluzd"))

        #expect(InstallationCheck.firstProblem(bundle: bundle, owner: getuid())?.issue == .missing)
    }
}

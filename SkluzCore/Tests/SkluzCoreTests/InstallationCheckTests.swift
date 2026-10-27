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
        try fm.createDirectory(at: bundle.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        for (file, mode) in [("Contents/MacOS/skluzd", 0o755), ("Contents/Library/LaunchDaemons/net.haruni.skluzd.plist", 0o644),
                             ("Contents/Helpers/skluz", 0o755), ("Contents/Resources/skluz-uninstall.sh", 0o644)] {
            fm.createFile(atPath: bundle.appending(path: file).path(percentEncoded: false), contents: Data(),
                          attributes: [.posixPermissions: mode])
        }
        for dir in ["", "Contents", "Contents/MacOS", "Contents/Library", "Contents/Library/LaunchDaemons", "Contents/Helpers",
                    "Contents/Resources"] {
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
        // The temporary parent folders belong to the user too: they are
        // reported first, as an ancestor others than root could rewrite.
        let problem = try #require(InstallationCheck.firstProblem(bundle: bundle, owner: 0))
        #expect(problem.issue == .unsafeAncestor(mode: 0o755) || problem.issue == .unsafeAncestor(mode: 0o700)
                || problem.issue == .wrongOwner(uid: getuid()))
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

    @Test func worldWritableParentIsRefused() throws {
        let bundle = try makeBundle()
        defer { cleanup(bundle) }
        let parent = bundle.deletingLastPathComponent().path(percentEncoded: false)
        chmod(parent, 0o777)

        let problem = try #require(InstallationCheck.firstProblem(bundle: bundle, owner: getuid()))
        #expect(problem.issue == .unsafeAncestor(mode: 0o777))
    }

    /// /Applications is root:admin 775 on every Mac: accepted as a parent.
    @Test func applicationsFolderAsShippedIsAccepted() {
        #expect(InstallationCheck.firstUnsafeAncestor(of: "/Applications/Skluz.app", owner: 0) == nil)
    }

    @Test func userHomeIsNotASafeParentForRoot() {
        let problem = InstallationCheck.firstUnsafeAncestor(of: NSHomeDirectory() + "/Skluz.app", owner: 0)
        guard case .unsafeAncestor = problem?.issue else {
            Issue.record("Expected the user-owned home folder to be refused, got \(String(describing: problem))")
            return
        }
        #expect(problem?.path == NSHomeDirectory())
    }
}

import AppKit
import Foundation
import ServiceManagement
import SkluzCore

/// Thin wrapper around `SMAppService.daemon` for skluzd (`PLAN_SKLUZD.md`
/// phase 3).
enum DaemonManager {
    static let plistName = "net.haruni.skluzd.plist"
    static let requiredBundlePath = "/Applications/Skluz.app"

    enum Failure: LocalizedError {
        case notInApplications
        case staleBundle

        var errorDescription: String? {
            switch self {
            case .notInApplications: "Déplacez Skluz dans le dossier Applications, puis relancez-le."
            case .staleBundle:       "Skluz a été mis à jour pendant qu'il tournait : relancez-le."
            }
        }
    }

    private static var service: SMAppService {
        .daemon(plistName: plistName)
    }

    static var status: SMAppService.Status {
        service.status
    }

    /// launchd records the app location at registration: from a mounted DMG,
    /// Downloads (App Translocation) or a user-writable folder, the root
    /// daemon would break or be replaceable by any process of the user.
    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path == requiredBundlePath
    }

    /// Why the installed bundle cannot host the root daemon: a bundle the
    /// user can write lets their processes swap in another team-signed
    /// `skluzd` that launchd would run as root.
    static var installationProblem: InstallationCheck.Problem? {
        InstallationCheck.firstProblem(bundle: Bundle.main.bundleURL)
    }

    /// The bundle on disk is not the one this process was launched from (an
    /// update replaced or removed it). macOS then cannot tie the running app
    /// to its bundle and refuses to register the service ("Operation not
    /// permitted"): the app must be relaunched.
    static var isRunningStaleBundle: Bool {
        let infoPlist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        guard let onDisk = NSDictionary(contentsOf: infoPlist) else { return true }
        return onDisk["CFBundleVersion"] as? String != Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// Opens a new instance from the bundle on disk, then quits this one.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path(percentEncoded: false)]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// App version, as compared with the daemon's.
    static var appVersion: (short: String, build: String) {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
         Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
    }

    /// Registers the daemon. The first time, macOS waits for the user's
    /// approval: the Login Items settings are then opened.
    static func register() throws {
        guard isInstalledInApplications else { throw Failure.notInApplications }
        guard !isRunningStaleBundle else { throw Failure.staleBundle }
        if let problem = installationProblem { throw problem }
        defer {
            if status == .requiresApproval { openSettings() }
        }
        try service.register()
    }

    static func unregister() throws {
        guard isInstalledInApplications else { throw Failure.notInApplications }
        try service.unregister()
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    "Désactivé"
        case .enabled:          "Actif"
        case .requiresApproval: "En attente d'approbation"
        case .notFound:         "Introuvable dans l'app"
        @unknown default:       "Inconnu"
        }
    }
}

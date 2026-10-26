import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.daemon` for skluzd (`PLAN_SKLUZD.md`
/// phase 3).
enum DaemonManager {
    static let plistName = "net.haruni.skluzd.plist"
    static let requiredBundlePath = "/Applications/Skluz.app"

    enum Failure: LocalizedError {
        case notInApplications

        var errorDescription: String? {
            "Déplacez Skluz dans le dossier Applications, puis relancez-le."
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

    /// Registers the daemon. The first time, macOS waits for the user's
    /// approval: the Login Items settings are then opened.
    static func register() throws {
        guard isInstalledInApplications else { throw Failure.notInApplications }
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

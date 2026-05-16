import Foundation
import ServiceManagement

/// Fin wrapper autour de SMAppService.mainApp (plan §9).
enum LaunchAtLoginManager {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// L'utilisateur a activé le lancement mais doit l'approuver dans
    /// Réglages Système → Général → Ouverture.
    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

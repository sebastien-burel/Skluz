import Foundation

/// Why a `TunnelConfig` cannot be turned into an ssh command. Messages are
/// user-facing (French UI).
public enum TunnelValidationError: Error, Equatable, Sendable, LocalizedError {
    case controlCharacters(field: String)
    case invalidHost(field: String, value: String)
    case invalidUser(String)
    case invalidPort(field: String, value: Int)
    case invalidProxyJump(String)
    case invalidBindAddress(String)
    case bindRequiresOptIn(String)
    case invalidKeyName(String)
    case managedKeyRequiresSystemMode
    case systemRequiresLocalForward
    case systemRequiresUser
    case systemRequiresManagedKey
    case systemForbidsProxyJump
    case systemForbidsExtraArgs
    case unsafeSystemPath(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .controlCharacters(let field):
            "Le champ « \(field) » contient des caractères de contrôle."
        case .invalidHost(let field, let value):
            "\(field.prefix(1).uppercased() + field.dropFirst()) invalide : « \(value) » (lettres, chiffres, . _ - : ; pas de « - » en tête)."
        case .invalidUser(let value):
            "Utilisateur invalide : « \(value) » (lettres, chiffres, . _ - ; pas de « - » en tête)."
        case .invalidPort(let field, let value):
            "\(field.prefix(1).uppercased() + field.dropFirst()) invalide : \(value) (1 à 65535)."
        case .invalidProxyJump(let value):
            "ProxyJump invalide : « \(value) »."
        case .invalidBindAddress(let value):
            "Adresse d'écoute invalide : « \(value) »."
        case .bindRequiresOptIn(let value):
            "Écouter sur « \(value) » expose le tunnel au réseau : activez explicitement l'option."
        case .invalidKeyName(let value):
            "Nom de clé invalide : « \(value) » (lettres, chiffres, _ et -)."
        case .managedKeyRequiresSystemMode:
            "Une clé dédiée du service système n'est utilisable qu'en mode Système."
        case .systemRequiresLocalForward:
            "Le mode Système ne gère que les redirections locales (-L)."
        case .systemRequiresUser:
            "Le mode Système exige un utilisateur SSH explicite."
        case .systemRequiresManagedKey:
            "Le mode Système exige une clé dédiée du service système."
        case .systemForbidsProxyJump:
            "ProxyJump n'est pas autorisé en mode Système."
        case .systemForbidsExtraArgs:
            "Les arguments additionnels ne sont pas autorisés en mode Système."
        case .unsafeSystemPath(let path):
            "Chemin système inutilisable : « \(path) »."
        }
    }
}

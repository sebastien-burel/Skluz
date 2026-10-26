import Foundation

/// Refusals of forwarded connections while ssh itself keeps running
/// (`PLAN_SKLUZD.md` phase 8): the tunnel is up but carries nothing.
public enum ForwardFailure {
    /// How long a refusal keeps being reported after the last one.
    public static let window: TimeInterval = 10 * 60

    /// `channel 3: open failed: administratively prohibited: open failed`
    /// `channel 3: open failed: connect failed: Connection refused`
    public static func isForwardFailure(_ line: String) -> Bool {
        line.contains("open failed:")
    }

    /// An actionable message for the user.
    public static func message(for line: String, remoteHost: String, remotePort: Int) -> String {
        let target = "\(remoteHost):\(remotePort)"
        if line.contains("administratively prohibited") {
            return "Le serveur refuse la redirection vers \(target) : la ligne authorized_keys de la clé "
                + "(permitopen) n'autorise pas cette destination."
        }
        if line.contains("Connection refused") || line.contains("connect failed") {
            return "Aucun service n'écoute sur \(target) côté serveur : les connexions au tunnel échouent."
        }
        return "Le serveur refuse les connexions du tunnel : \(line)"
    }
}

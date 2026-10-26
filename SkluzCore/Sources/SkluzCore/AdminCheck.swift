import Foundation
import Darwin
import Darwin.membership

/// Membership of the admin group: the daemon restricts mutations to admins,
/// and the app greys out the matching actions for everyone else.
public enum AdminCheck {
    public static func isAdmin(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let group = getgrnam("admin") else { return false }
        var userUUID = UUID().uuid
        var groupUUID = UUID().uuid
        var isMember: Int32 = 0
        let ok = withUnsafeMutableBytes(of: &userUUID) { user in
            withUnsafeMutableBytes(of: &groupUUID) { grp in
                let u = user.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let g = grp.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return mbr_uid_to_uuid(uid, u) == 0
                    && mbr_gid_to_uuid(group.pointee.gr_gid, g) == 0
                    && mbr_check_membership(u, g, &isMember) == 0
            }
        }
        return ok && isMember != 0
    }

    public static var isCurrentUserAdmin: Bool {
        isAdmin(uid: getuid())
    }
}

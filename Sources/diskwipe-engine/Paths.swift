import Foundation

/// Resolves the *invoking* user's home, even when the engine runs as root via sudo.
/// (NSHomeDirectory() would return /var/root under sudo, putting reports in the wrong place.)
enum Paths {
    static var userHome: String {
        let env = ProcessInfo.processInfo.environment
        if let user = env["SUDO_USER"], !user.isEmpty, user != "root",
           let pw = getpwnam(user), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        let home = NSHomeDirectory()
        return home
    }
    static var reportsDir: String {
        (userHome as NSString).appendingPathComponent("disk-reports")
    }

    /// Give a file/dir back to the invoking user (so root-written reports aren't owned by root).
    static func chownToUser(_ path: String) {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SUDO_USER"], !user.isEmpty, user != "root",
              let pw = getpwnam(user) else { return }
        chown(path, pw.pointee.pw_uid, pw.pointee.pw_gid)
    }
}

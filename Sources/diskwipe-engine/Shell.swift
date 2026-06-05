import Foundation

/// Result of running an external command.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

enum Shell {
    /// Run a command to completion, capturing stdout/stderr. Blocking.
    /// Every invocation is logged; failures log full stderr/stdout for diagnosis.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> ShellResult {
        let cmd = "\(launchPath) \(args.joined(separator: " "))"
        Logger.info("shell", "→ \(cmd)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            Logger.error("shell", "✗ spawn failed: \(error) cmd=\(cmd)")
            return ShellResult(exitCode: -1, stdout: "", stderr: "spawn failed: \(error)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let result = ShellResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
        if result.ok {
            Logger.info("shell", "✓ exit=0 \(launchPath) \(args.first ?? "")")
        } else {
            let se = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let so = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.error("shell",
                "✗ exit=\(result.exitCode) cmd=\(cmd)\n    stderr: \(se)\n    stdout: \(so)")
        }
        return result
    }

    // Common tool paths (Homebrew on Apple Silicon + system).
    static let diskutil = "/usr/sbin/diskutil"
    static var smartctl: String {
        for p in ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/local/sbin/smartctl"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/bin/smartctl"
    }
    static var mke2fs: String {
        for p in ["/opt/homebrew/opt/e2fsprogs/sbin/mke2fs",
                  "/usr/local/opt/e2fsprogs/sbin/mke2fs"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs"
    }
}

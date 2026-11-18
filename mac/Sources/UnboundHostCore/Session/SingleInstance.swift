import Foundation

/// Only one Unbound host (CLI or app) can own the virtual display at a time.
public enum SingleInstance {
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// Returns nil on success, or the pid string of the instance already running.
    public static func acquire() -> String? {
        if lockFD >= 0 { return nil }
        let path = NSTemporaryDirectory() + "unbound-host.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let pid = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            close(fd)
            return pid
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd // held until the process exits
        return nil
    }
}

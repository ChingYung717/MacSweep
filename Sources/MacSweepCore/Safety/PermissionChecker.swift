import Darwin
import Foundation

public struct PermissionStatus: Sendable, Equatable {
    public let hasFullDiskAccess: Bool
    public let probePathUsed: String

    public init(hasFullDiskAccess: Bool, probePathUsed: String) {
        self.hasFullDiskAccess = hasFullDiskAccess
        self.probePathUsed = probePathUsed
    }
}

public enum PermissionChecker {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public static let appManagementSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
    )!

    public static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    public static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    /// Non-invasive Full Disk Access check.
    /// Probes `/Library/Application Support/com.apple.TCC/TCC.db` (0644 root:wheel) using raw `open(O_RDONLY)`.
    /// Unlike reading another app's Container, this never triggers a macOS "access other app's data" prompt.
    public static func checkFullDiskAccess(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PermissionStatus {
        let systemTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = Darwin.open(systemTCC, O_RDONLY)
        if fd >= 0 {
            Darwin.close(fd)
            return PermissionStatus(hasFullDiskAccess: true, probePathUsed: systemTCC)
        }
        let err = errno
        if err == EPERM || err == EACCES {
            return PermissionStatus(hasFullDiskAccess: false, probePathUsed: systemTCC)
        }

        // Fallback only if system TCC.db does not exist (ENOENT).
        let fallbacks = [
            homeDirectory.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            homeDirectory.appendingPathComponent("Library/Safari").path,
            homeDirectory.appendingPathComponent("Library/Mail").path,
        ]
        for path in fallbacks {
            let f = Darwin.open(path, O_RDONLY)
            if f >= 0 {
                Darwin.close(f)
                return PermissionStatus(hasFullDiskAccess: true, probePathUsed: path)
            }
            if errno == EPERM || errno == EACCES {
                return PermissionStatus(hasFullDiskAccess: false, probePathUsed: path)
            }
        }

        return PermissionStatus(hasFullDiskAccess: false, probePathUsed: systemTCC)
    }

    /// Checks whether a specific directory can be read (detects TCC denial such as Chrome profiles without FDA).
    public static func canReadDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

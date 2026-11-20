import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public enum ProcessRunner {
    /// Runs an executable synchronously and captures stdout/stderr without deadlocking pipes.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            // Merge (not replace) so PATH / HOME / TMPDIR etc. are preserved; caller values win on conflict.
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outGroup = DispatchGroup()
        let outBox = LockedDataBox()
        let errBox = LockedDataBox()

        outGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            outGroup.leave()
        }

        outGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            outGroup.leave()
        }

        process.waitUntilExit()
        outGroup.wait()

        let stdout = String(data: outBox.get(), encoding: .utf8) ?? ""
        let stderr = String(data: errBox.get(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// POSIX single-quote escaping: `'foo'bar'` -> `'foo'\''bar'`.
    public static func posixQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string literal for embedding inside an AppleScript double-quoted string.
    public static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

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
    /// Rejects any NUL byte (`\0`) in executable, arguments, or environment to prevent uncatchable
    /// Objective-C `NSInvalidArgumentException` (`SIGABRT`) inside Foundation's `Process`.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil
    ) -> ProcessResult {
        if executable.isEmpty || executable.contains("\0")
            || arguments.contains(where: { $0.contains("\0") })
            || (environment?.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") }) ?? false) {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "Invalid NUL byte in process invocation")
        }

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

        let inPipe: Pipe? = stdinData != nil ? Pipe() : nil
        if let inPipe {
            process.standardInput = inPipe
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        if let inPipe, let stdinData {
            DispatchQueue.global(qos: .userInitiated).async {
                let fh = inPipe.fileHandleForWriting
                if !stdinData.isEmpty {
                    try? fh.write(contentsOf: stdinData)
                }
                try? fh.close()
            }
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
    /// Note: For strings that may contain CR/LF (e.g. `Icon\r`), prefer `appleScriptExpression(_:)`.
    public static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Produces a complete AppleScript string expression preserving literal `\r` and `\n`
    /// (AppleScript compiler otherwise silently normalizes raw `\r` inside quotes into `\n`).
    public static func appleScriptExpression(_ value: String) -> String {
        var parts: [String] = []
        var buffer = ""

        func flushBuffer() {
            if !buffer.isEmpty || parts.isEmpty {
                parts.append("\"\(appleScriptEscape(buffer))\"")
                buffer = ""
            }
        }

        for scalar in value.unicodeScalars {
            if scalar == "\r" {
                if !buffer.isEmpty { flushBuffer() }
                parts.append("return")
            } else if scalar == "\n" {
                if !buffer.isEmpty { flushBuffer() }
                parts.append("linefeed")
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }
        if !buffer.isEmpty || parts.isEmpty {
            flushBuffer()
        }
        return parts.joined(separator: " & ")
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

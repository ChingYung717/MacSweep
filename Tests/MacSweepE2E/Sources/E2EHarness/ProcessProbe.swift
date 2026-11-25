import Darwin
import Foundation

public struct ProcessProbeResult: Sendable, Equatable {
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let timedOut: Bool
    public let durationSeconds: TimeInterval
    public let stdoutData: Data
    public let stderrData: Data
    public let stdout: String
    public let stderr: String

    public init(
        exitCode: Int32,
        terminationReason: Process.TerminationReason,
        timedOut: Bool,
        durationSeconds: TimeInterval,
        stdoutData: Data,
        stderrData: Data,
        stdout: String,
        stderr: String
    ) {
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.timedOut = timedOut
        self.durationSeconds = durationSeconds
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        !timedOut && terminationReason == .exit && exitCode == 0
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.withLock { storage = data }
    }

    func get() -> Data {
        lock.withLock { storage }
    }
}

private final class SendableRef<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func trigger() -> Bool {
        lock.withLock {
            if signaled { return false }
            signaled = true
            return true
        }
    }
}

public enum ProcessProbe: Sendable {
    public static let swiftPath = "/usr/bin/swift"
    public static let codesignPath = "/usr/bin/codesign"
    public static let otoolPath = "/usr/bin/otool"
    public static let lipoPath = "/usr/bin/lipo"
    public static let sipsPath = "/usr/bin/sips"

    public static func run(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true,
        stdinData: Data? = nil,
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        let start = Date()

        if containsNulByte(executable)
            || arguments.contains(where: containsNulByte)
            || (environment?.contains { containsNulByte($0.key) || containsNulByte($0.value) } ?? false)
            || (workingDirectory.map { containsNulByte($0.path) } ?? false) {
            let msg = "ProcessProbe rejected argument containing NUL byte"
            return ProcessProbeResult(
                exitCode: -1,
                terminationReason: .uncaughtSignal,
                timedOut: false,
                durationSeconds: Date().timeIntervalSince(start),
                stdoutData: Data(),
                stderrData: Data(msg.utf8),
                stdout: "",
                stderr: msg
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        if let environment {
            if inheritEnvironment {
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    merged[key] = value
                }
                process.environment = merged
            } else {
                process.environment = environment
            }
        } else if !inheritEnvironment {
            process.environment = [:]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let semaphore = DispatchSemaphore(value: 0)
        let semaphoreRef = SendableRef(semaphore)
        let once = OnceFlag()
        process.terminationHandler = { _ in
            if once.trigger() {
                semaphoreRef.value.signal()
            }
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
            if let inPipe {
                try? inPipe.fileHandleForReading.close()
                try? inPipe.fileHandleForWriting.close()
            }
            let msg = "Failed to launch \(executable): \(error)"
            return ProcessProbeResult(
                exitCode: -1,
                terminationReason: .exit,
                timedOut: false,
                durationSeconds: Date().timeIntervalSince(start),
                stdoutData: Data(),
                stderrData: Data(msg.utf8),
                stdout: "",
                stderr: msg
            )
        }

        // Write stdin asynchronously on a background queue if provided, then close.
        if let stdinData, let inPipe {
            let writeHandle = inPipe.fileHandleForWriting
            _ = Darwin.fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
            let writeHandleRef = SendableRef(writeHandle)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writeHandleRef.value.write(contentsOf: stdinData)
                try? writeHandleRef.value.close()
            }
        }

        let outBox = LockedDataBox()
        let errBox = LockedDataBox()
        let ioGroup = DispatchGroup()
        let outReadRef = SendableRef(outPipe.fileHandleForReading)
        let errReadRef = SendableRef(errPipe.fileHandleForReading)
        let ioQueue = DispatchQueue.global(qos: .userInitiated)

        ioGroup.enter()
        ioQueue.async {
            outBox.set((try? outReadRef.value.readToEnd()) ?? Data())
            ioGroup.leave()
        }

        ioGroup.enter()
        ioQueue.async {
            errBox.set((try? errReadRef.value.readToEnd()) ?? Data())
            ioGroup.leave()
        }

        let clampedTimeout = max(0.05, timeoutSeconds)
        let waitResult = semaphore.wait(timeout: .now() + clampedTimeout)
        var timedOut = false

        if waitResult == .timedOut {
            timedOut = true
            let pid = process.processIdentifier
            if pid > 0 {
                _ = Darwin.kill(pid, SIGTERM)
            }
            if semaphore.wait(timeout: .now() + 0.5) == .timedOut {
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
                _ = semaphore.wait(timeout: .now() + 1.0)
            }
        }

        // Wait bounded time for pipe drains; if a grandchild held descriptors open after timeout,
        // close the read handles to unblock the drain threads. Always close read handles afterward
        // so tight synchronous loops without autoreleasepool do not accumulate pipe FDs.
        if ioGroup.wait(timeout: .now() + 2.0) == .timedOut {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            _ = ioGroup.wait(timeout: .now() + 1.0)
        } else {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        let outData = outBox.get()
        let errData = errBox.get()
        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus
        let reason: Process.TerminationReason = process.isRunning ? .uncaughtSignal : process.terminationReason

        return ProcessProbeResult(
            exitCode: exitCode,
            terminationReason: reason,
            timedOut: timedOut,
            durationSeconds: Date().timeIntervalSince(start),
            stdoutData: outData,
            stderrData: errData,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    public static func runAsync(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true,
        stdinData: Data? = nil,
        timeoutSeconds: TimeInterval = 30.0
    ) async -> ProcessProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    inheritEnvironment: inheritEnvironment,
                    stdinData: stdinData,
                    timeoutSeconds: timeoutSeconds
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Explicit /usr/bin Tool Helpers (avoids Anaconda/Homebrew PATH shadowing)

    public static func swift(
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 180.0
    ) -> ProcessProbeResult {
        run(
            executable: swiftPath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func codesign(
        arguments: [String],
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        run(executable: codesignPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    public static func otool(
        arguments: [String],
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        run(executable: otoolPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    public static func lipo(
        arguments: [String],
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        run(executable: lipoPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    public static func sips(
        arguments: [String],
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        run(executable: sipsPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - MacSweep Artifact Builders & Runners

    public static func buildProduct(
        repoRoot: URL,
        product: String,
        configuration: String = "debug",
        scratchPath: URL,
        timeoutSeconds: TimeInterval = 180.0
    ) -> (buildResult: ProcessProbeResult, executableURL: URL?) {
        let baseArgs = [
            "build",
            "--package-path", repoRoot.path,
            "--scratch-path", scratchPath.path,
            "-c", configuration,
        ]
        let buildResult = swift(
            arguments: baseArgs + ["--product", product],
            workingDirectory: repoRoot,
            timeoutSeconds: timeoutSeconds
        )
        guard buildResult.succeeded else {
            return (buildResult, nil)
        }
        let binPathResult = swift(
            arguments: baseArgs + ["--show-bin-path"],
            workingDirectory: repoRoot,
            timeoutSeconds: 30.0
        )
        guard binPathResult.succeeded else {
            return (buildResult, nil)
        }
        let binDir = binPathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !binDir.isEmpty else {
            return (buildResult, nil)
        }
        let exeURL = URL(fileURLWithPath: binDir).appendingPathComponent(product)
        return (buildResult, exeURL)
    }

    public static func runMakeApp(
        repoRoot: URL,
        outputDir: URL,
        scratchPath: URL,
        extraEnv: [String: String] = [:],
        timeoutSeconds: TimeInterval = 240.0
    ) -> ProcessProbeResult {
        var env = extraEnv
        env["MACSWEEP_SCRATCH_PATH"] = scratchPath.path
        let scriptPath = repoRoot.appendingPathComponent("make_app.sh").path
        return run(
            executable: "/bin/bash",
            arguments: [scriptPath, outputDir.path],
            workingDirectory: repoRoot,
            environment: env,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func runMacSweepApp(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 30.0
    ) -> ProcessProbeResult {
        run(
            executable: executableURL.path,
            arguments: arguments,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func runMacSweepChecks(
        executableURL: URL,
        arguments: [String] = [],
        timeoutSeconds: TimeInterval = 60.0
    ) -> ProcessProbeResult {
        run(
            executable: executableURL.path,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func containsNulByte(_ string: String) -> Bool {
        string.utf8.contains(0)
    }
}

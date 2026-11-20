import Foundation

final class CheckRunner {
    private var passed = 0
    private var failed = 0

    func run(_ name: String, _ block: () throws -> Void) {
        do {
            try block()
            passed += 1
            print("  ✅ \(name)")
        } catch {
            failed += 1
            fputs("  ❌ \(name): \(error)\n", stderr)
        }
    }

    func expect(_ condition: Bool, _ message: String = "Assertion failed", file: String = #fileID, line: Int = #line) throws {
        if !condition {
            throw CheckFailure(message: "\(message) (\(file):\(line))")
        }
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
        if lhs != rhs {
            let prefix = message.isEmpty ? "" : "\(message) — "
            throw CheckFailure(message: "\(prefix)expected '\(rhs)', got '\(lhs)' (\(file):\(line))")
        }
    }

    func makeTempSandbox(prefix: String = "macsweep-check") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func summaryAndExit() -> Never {
        print("\nMacSweepChecks summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

import Darwin
import Foundation

public enum E2ETierSelection: Sendable, Equatable {
    case all
    case tier(Int)

    public var cliValue: String {
        switch self {
        case .all:
            return "all"
        case let .tier(t):
            return "\(t)"
        }
    }

    public func matches(_ tier: Int) -> Bool {
        switch self {
        case .all:
            return true
        case let .tier(selected):
            return tier == selected
        }
    }
}

public struct E2ECase: Sendable {
    public let id: String
    public let tier: Int
    public let feature: String
    public let name: String
    public let body: @Sendable () async throws -> Void

    public init(
        id: String,
        tier: Int,
        feature: String,
        name: String,
        body: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.tier = tier
        self.feature = feature
        self.name = name
        self.body = body
    }
}

public struct E2ECaseResult: Codable, Sendable, Equatable {
    public let id: String
    public let tier: Int
    public let feature: String
    public let name: String
    public let status: String
    public let durationMs: Int
    public let error: String?

    public init(
        id: String,
        tier: Int,
        feature: String,
        name: String,
        status: String,
        durationMs: Int,
        error: String?
    ) {
        self.id = id
        self.tier = tier
        self.feature = feature
        self.name = name
        self.status = status
        self.durationMs = durationMs
        self.error = error
    }
}

public struct E2ETierCount: Codable, Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let total: Int

    public init(passed: Int, failed: Int, total: Int) {
        self.passed = passed
        self.failed = failed
        self.total = total
    }
}

public struct E2EReport: Codable, Sendable, Equatable {
    public let probeName: String
    public let tierFilter: String
    public let filterPattern: String?
    public let timestampISO8601: String
    public let durationMs: Int
    public let summary: E2ETierCount
    public let tierCounts: [String: E2ETierCount]
    public let cases: [E2ECaseResult]

    public init(
        probeName: String,
        tierFilter: String,
        filterPattern: String?,
        timestampISO8601: String,
        durationMs: Int,
        summary: E2ETierCount,
        tierCounts: [String: E2ETierCount],
        cases: [E2ECaseResult]
    ) {
        self.probeName = probeName
        self.tierFilter = tierFilter
        self.filterPattern = filterPattern
        self.timestampISO8601 = timestampISO8601
        self.durationMs = durationMs
        self.summary = summary
        self.tierCounts = tierCounts
        self.cases = cases
    }
}

public struct E2EAssertionFailure: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let file: String
    public let line: Int

    public init(_ message: String, file: String = #fileID, line: Int = #line) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String {
        "\(file):\(line): \(message)"
    }
}

public enum E2ECLIError: Error, CustomStringConvertible, Sendable {
    case missingValue(String)
    case invalidTier(String)
    case unknownFlag(String)
    case unexpectedArgument(String)

    public var description: String {
        switch self {
        case let .missingValue(flag):
            return "Missing value for flag \(flag)"
        case let .invalidTier(value):
            return "Invalid tier '\(value)'. Expected 1, 2, 3, 4, or all."
        case let .unknownFlag(flag):
            return "Unknown flag: \(flag)"
        case let .unexpectedArgument(arg):
            return "Unexpected positional argument: \(arg)"
        }
    }
}

public struct E2ECLIConfig: Sendable, Equatable {
    public let tierSelection: E2ETierSelection
    public let jsonOutputPath: String?
    public let filterPattern: String?
    public let listOnly: Bool
    public let showHelp: Bool

    public init(
        tierSelection: E2ETierSelection = .all,
        jsonOutputPath: String? = nil,
        filterPattern: String? = nil,
        listOnly: Bool = false,
        showHelp: Bool = false
    ) {
        self.tierSelection = tierSelection
        self.jsonOutputPath = jsonOutputPath
        self.filterPattern = filterPattern
        self.listOnly = listOnly
        self.showHelp = showHelp
    }
}

public final class E2ERunner: @unchecked Sendable {
    public let probeName: String
    private let lock = NSLock()
    private var cases: [E2ECase] = []

    public init(probeName: String) {
        self.probeName = probeName
    }

    public func register(
        id: String,
        tier: Int,
        feature: String,
        name: String,
        body: @escaping @Sendable () async throws -> Void
    ) {
        precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Case id cannot be empty")
        precondition((1...4).contains(tier), "Tier must be in 1...4, got \(tier)")
        precondition(!feature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Feature cannot be empty")
        let entry = E2ECase(id: id, tier: tier, feature: feature, name: name, body: body)
        lock.withLock {
            precondition(!cases.contains(where: { $0.id == id }), "Duplicate E2E test case id: \(id)")
            cases.append(entry)
        }
    }

    public func registeredCases() -> [E2ECase] {
        lock.withLock { cases }
    }

    public static func parseArguments(_ args: [String] = CommandLine.arguments) throws -> E2ECLIConfig {
        var tierSelection: E2ETierSelection = .all
        var jsonPath: String?
        var filterPattern: String?
        var listOnly = false
        var showHelp = false

        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            if arg == "--help" || arg == "-h" {
                showHelp = true
                idx += 1
            } else if arg == "--list" {
                listOnly = true
                idx += 1
            } else if arg == "--tier" {
                guard idx + 1 < args.count else { throw E2ECLIError.missingValue("--tier") }
                tierSelection = try parseTierValue(args[idx + 1])
                idx += 2
            } else if arg.hasPrefix("--tier=") {
                let value = String(arg.dropFirst("--tier=".count))
                tierSelection = try parseTierValue(value)
                idx += 1
            } else if arg == "--json" {
                guard idx + 1 < args.count else { throw E2ECLIError.missingValue("--json") }
                let value = args[idx + 1]
                guard !value.isEmpty else { throw E2ECLIError.missingValue("--json") }
                jsonPath = value
                idx += 2
            } else if arg.hasPrefix("--json=") {
                let value = String(arg.dropFirst("--json=".count))
                guard !value.isEmpty else { throw E2ECLIError.missingValue("--json") }
                jsonPath = value
                idx += 1
            } else if arg == "--filter" {
                guard idx + 1 < args.count else { throw E2ECLIError.missingValue("--filter") }
                filterPattern = args[idx + 1]
                idx += 2
            } else if arg.hasPrefix("--filter=") {
                filterPattern = String(arg.dropFirst("--filter=".count))
                idx += 1
            } else if arg.hasPrefix("-") {
                throw E2ECLIError.unknownFlag(arg)
            } else {
                throw E2ECLIError.unexpectedArgument(arg)
            }
        }

        return E2ECLIConfig(
            tierSelection: tierSelection,
            jsonOutputPath: jsonPath,
            filterPattern: (filterPattern?.isEmpty == true) ? nil : filterPattern,
            listOnly: listOnly,
            showHelp: showHelp
        )
    }

    private static func parseTierValue(_ raw: String) throws -> E2ETierSelection {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "all" {
            return .all
        }
        if let n = Int(lower), (1...4).contains(n) {
            return .tier(n)
        }
        throw E2ECLIError.invalidTier(raw)
    }

    private func matchingCases(for config: E2ECLIConfig) -> [E2ECase] {
        let snapshot = registeredCases()
        return snapshot.filter { item in
            guard config.tierSelection.matches(item.tier) else { return false }
            if let pattern = config.filterPattern, !pattern.isEmpty {
                let lower = pattern.lowercased()
                let matchesID = item.id.lowercased().contains(lower)
                let matchesFeature = item.feature.lowercased().contains(lower)
                let matchesName = item.name.lowercased().contains(lower)
                return matchesID || matchesFeature || matchesName
            }
            return true
        }
    }

    public func run(config: E2ECLIConfig) async -> E2EReport {
        let selected = matchingCases(for: config)
        let overallStart = DispatchTime.now().uptimeNanoseconds

        var results: [E2ECaseResult] = []
        var totalPassed = 0
        var totalFailed = 0
        var tierTallies: [Int: (passed: Int, failed: Int, total: Int)] = [:]

        for testCase in selected {
            let start = DispatchTime.now().uptimeNanoseconds
            var failureReason: String?
            do {
                try await testCase.body()
            } catch {
                failureReason = String(describing: error)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = Int((end >= start ? end - start : 0) / 1_000_000)

            var tally = tierTallies[testCase.tier] ?? (0, 0, 0)
            tally.total += 1

            if let reason = failureReason {
                totalFailed += 1
                tally.failed += 1
                let singleLine = reason
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                print("[TIER-\(testCase.tier)][\(testCase.feature)] \(testCase.id): FAIL (\(singleLine))")
                results.append(E2ECaseResult(
                    id: testCase.id,
                    tier: testCase.tier,
                    feature: testCase.feature,
                    name: testCase.name,
                    status: "FAIL",
                    durationMs: elapsedMs,
                    error: singleLine
                ))
            } else {
                totalPassed += 1
                tally.passed += 1
                print("[TIER-\(testCase.tier)][\(testCase.feature)] \(testCase.id): PASS")
                results.append(E2ECaseResult(
                    id: testCase.id,
                    tier: testCase.tier,
                    feature: testCase.feature,
                    name: testCase.name,
                    status: "PASS",
                    durationMs: elapsedMs,
                    error: nil
                ))
            }
            tierTallies[testCase.tier] = tally
            fflush(stdout)
        }

        let overallEnd = DispatchTime.now().uptimeNanoseconds
        let totalDurationMs = Int((overallEnd >= overallStart ? overallEnd - overallStart : 0) / 1_000_000)
        let totalCount = totalPassed + totalFailed

        var tierCountsDict: [String: E2ETierCount] = [:]
        for (tier, tally) in tierTallies {
            tierCountsDict["\(tier)"] = E2ETierCount(passed: tally.passed, failed: tally.failed, total: tally.total)
        }

        print("E2E_SUMMARY tier=\(config.tierSelection.cliValue) passed=\(totalPassed) failed=\(totalFailed) total=\(totalCount)")
        fflush(stdout)

        let isoFormatter = ISO8601DateFormatter()
        return E2EReport(
            probeName: probeName,
            tierFilter: config.tierSelection.cliValue,
            filterPattern: config.filterPattern,
            timestampISO8601: isoFormatter.string(from: Date()),
            durationMs: totalDurationMs,
            summary: E2ETierCount(passed: totalPassed, failed: totalFailed, total: totalCount),
            tierCounts: tierCountsDict,
            cases: results
        )
    }

    public func writeJSON(_ report: E2EReport, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    public func runAndExit(arguments: [String] = CommandLine.arguments) async -> Never {
        let config: E2ECLIConfig
        do {
            config = try Self.parseArguments(arguments)
        } catch {
            Self.writeStderr("[\(probeName)] CLI error: \(error)\n")
            Self.printUsage(probeName: probeName)
            exit(2)
        }

        if config.showHelp {
            Self.printUsage(probeName: probeName)
            exit(0)
        }

        if config.listOnly {
            let selected = matchingCases(for: config)
            for item in selected {
                print("[TIER-\(item.tier)][\(item.feature)] \(item.id) — \(item.name)")
            }
            fflush(stdout)
            exit(0)
        }

        let report = await run(config: config)
        if let jsonPath = config.jsonOutputPath {
            do {
                try writeJSON(report, toPath: jsonPath)
            } catch {
                Self.writeStderr("[\(probeName)] Failed to write JSON report to \(jsonPath): \(error)\n")
                exit(2)
            }
        }

        exit(report.summary.failed == 0 ? 0 : 1)
    }

    private static func printUsage(probeName: String) {
        print("""
        Usage: \(probeName) [--tier <1|2|3|4|all>] [--filter <pattern>] [--json <path>] [--list] [--help]
        """)
        fflush(stdout)
    }

    private static func writeStderr(_ message: String) {
        fputs(message, stderr)
        fflush(stderr)
    }

    // MARK: - Static Assertion Helpers

    public static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "Assertion failed",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if !condition {
            throw E2EAssertionFailure(message(), file: file, line: line)
        }
    }

    public static func expectEqual<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if lhs != rhs {
            let extra = message()
            let detail = extra.isEmpty ? "Expected \(lhs) == \(rhs)" : "\(extra) (got \(lhs), expected \(rhs))"
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
    }

    public static func expectNotEqual<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if lhs == rhs {
            let extra = message()
            let detail = extra.isEmpty ? "Expected \(lhs) != \(rhs)" : "\(extra) (both equal to \(lhs))"
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
    }

    public static func expectContains(
        _ haystack: String,
        _ needle: String,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if !haystack.contains(needle) {
            let extra = message()
            let detail = extra.isEmpty ? "Expected '\(haystack)' to contain '\(needle)'" : "\(extra) (missing '\(needle)')"
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
    }

    public static func expectNotContains(
        _ haystack: String,
        _ needle: String,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if haystack.contains(needle) {
            let extra = message()
            let detail = extra.isEmpty ? "Expected string not to contain '\(needle)'" : "\(extra) (unexpected '\(needle)')"
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
    }

    public static func expectNil<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws {
        if let value {
            let extra = message()
            let detail = extra.isEmpty ? "Expected nil, got \(value)" : "\(extra) (got \(value))"
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
    }

    @discardableResult
    public static func expectNotNil<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) throws -> T {
        guard let unwrapped = value else {
            let extra = message()
            let detail = extra.isEmpty ? "Expected non-nil value" : extra
            throw E2EAssertionFailure(detail, file: file, line: line)
        }
        return unwrapped
    }

    @discardableResult
    public static func expectThrows(
        _ message: String = "Expected error to be thrown",
        file: String = #fileID,
        line: Int = #line,
        _ body: () throws -> Void
    ) throws -> Error {
        do {
            try body()
        } catch {
            return error
        }
        throw E2EAssertionFailure(message, file: file, line: line)
    }

    @discardableResult
    public static func expectThrowsAsync(
        _ message: String = "Expected async error to be thrown",
        file: String = #fileID,
        line: Int = #line,
        _ body: () async throws -> Void
    ) async throws -> Error {
        do {
            try await body()
        } catch {
            return error
        }
        throw E2EAssertionFailure(message, file: file, line: line)
    }
}

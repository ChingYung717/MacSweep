import Darwin
import E2EHarness
import Foundation
import MacSweepCore

private func resolveRepoRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["MACSWEEP_REPO_ROOT"], !env.isEmpty {
        return URL(fileURLWithPath: env).standardizedFileURL
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // E2EM4Probe
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // MacSweepE2E
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repoRoot
        .standardizedFileURL
}

private func resolveAppScratchPath(repoRoot: URL) -> URL {
    if let env = ProcessInfo.processInfo.environment["MACSWEEP_SCRATCH_PATH"], !env.isEmpty {
        return URL(fileURLWithPath: env).standardizedFileURL
    }
    return repoRoot
        .appendingPathComponent("Tests/MacSweepE2E/.build/app-scratch")
        .standardizedFileURL
}

private func listPNGFiles(in directory: URL) -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return items
        .filter { url in
            guard url.pathExtension.lowercased() == "png",
                  let vals = try? url.resourceValues(forKeys: keys),
                  vals.isSymbolicLink != true,
                  vals.isRegularFile == true else {
                return false
            }
            return true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private struct ExtractedMarkdownLink: Equatable {
    let path: String
    let isImage: Bool
}

private func stripMarkdownCodeBlocksAndSpans(from markdown: String) -> String {
    let normalized = markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var nonFencedLines: [String] = []
    nonFencedLines.reserveCapacity(lines.count)

    var openFenceChar: Character?
    var openFenceLength = 0

    for line in lines {
        let trimmedLeading = line.drop(while: { $0 == " " })
        let leadingSpaces = line.count - trimmedLeading.count

        if let fenceChar = openFenceChar {
            if leadingSpaces <= 3, trimmedLeading.first == fenceChar {
                let runCount = trimmedLeading.prefix(while: { $0 == fenceChar }).count
                let afterRun = trimmedLeading.dropFirst(runCount)
                if runCount >= openFenceLength && afterRun.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    openFenceChar = nil
                    openFenceLength = 0
                }
            }
            continue
        }

        if leadingSpaces <= 3, let first = trimmedLeading.first, (first == "`" || first == "~") {
            let runCount = trimmedLeading.prefix(while: { $0 == first }).count
            if runCount >= 3 {
                let infoString = trimmedLeading.dropFirst(runCount)
                if first == "~" || !infoString.contains("`") {
                    openFenceChar = first
                    openFenceLength = runCount
                    continue
                }
            }
        }
        nonFencedLines.append(line)
    }

    let withoutFences = nonFencedLines.joined(separator: "\n")
    var result = ""
    result.reserveCapacity(withoutFences.count)
    var i = withoutFences.startIndex
    while i < withoutFences.endIndex {
        if withoutFences[i] == "`" {
            var tickEnd = i
            while tickEnd < withoutFences.endIndex && withoutFences[tickEnd] == "`" {
                tickEnd = withoutFences.index(after: tickEnd)
            }
            let tickCount = withoutFences.distance(from: i, to: tickEnd)
            var search = tickEnd
            var closingEnd: String.Index?
            while search < withoutFences.endIndex {
                if withoutFences[search] == "`" {
                    var runEnd = search
                    while runEnd < withoutFences.endIndex && withoutFences[runEnd] == "`" {
                        runEnd = withoutFences.index(after: runEnd)
                    }
                    if withoutFences.distance(from: search, to: runEnd) == tickCount {
                        closingEnd = runEnd
                        break
                    }
                    search = runEnd
                } else {
                    search = withoutFences.index(after: search)
                }
            }
            if let end = closingEnd {
                let spanContent = withoutFences[tickEnd..<end]
                if !spanContent.contains("\n\n") {
                    result.append(" ")
                    i = end
                    continue
                }
            }
            result.append(contentsOf: withoutFences[i..<tickEnd])
            i = tickEnd
        } else {
            result.append(withoutFences[i])
            i = withoutFences.index(after: i)
        }
    }
    return result
}

private func normalizeRelativeLinkTarget(_ rawInput: String) -> String? {
    let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    if raw.hasPrefix("#") || raw.hasPrefix("//") {
        return nil
    }
    let lower = raw.lowercased()
    for scheme in ["http://", "https://", "mailto:", "data:", "javascript:", "tel:"] {
        if lower.hasPrefix(scheme) {
            return nil
        }
    }
    let cutoff = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? raw.endIndex
    let stripped = String(raw[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
}

private func parseMarkdownDestination(from inner: String) -> String? {
    let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("<") {
        var idx = trimmed.index(after: trimmed.startIndex)
        var dest = ""
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch == "\\" {
                let next = trimmed.index(after: idx)
                if next < trimmed.endIndex {
                    dest.append(trimmed[next])
                    idx = trimmed.index(after: next)
                    continue
                }
            }
            if ch == ">" {
                return dest
            }
            dest.append(ch)
            idx = trimmed.index(after: idx)
        }
        return nil
    }

    var idx = trimmed.startIndex
    var dest = ""
    while idx < trimmed.endIndex {
        let ch = trimmed[idx]
        if ch.isWhitespace {
            break
        }
        if ch == "\\" {
            let next = trimmed.index(after: idx)
            if next < trimmed.endIndex {
                dest.append(trimmed[next])
                idx = trimmed.index(after: next)
                continue
            }
        }
        dest.append(ch)
        idx = trimmed.index(after: idx)
    }
    return dest.isEmpty ? nil : dest
}

private func extractRelativeLinksWithKind(from markdown: String) -> [ExtractedMarkdownLink] {
    let cleaned = stripMarkdownCodeBlocksAndSpans(from: markdown)
    var links: [ExtractedMarkdownLink] = []

    var bracketIsImageStack: [Bool] = []
    var i = cleaned.startIndex
    while i < cleaned.endIndex {
        let ch = cleaned[i]
        if ch == "\\" {
            let next = cleaned.index(after: i)
            i = (next < cleaned.endIndex) ? cleaned.index(after: next) : cleaned.endIndex
            continue
        }
        if ch == "!" {
            let next = cleaned.index(after: i)
            if next < cleaned.endIndex && cleaned[next] == "[" {
                bracketIsImageStack.append(true)
                i = cleaned.index(after: next)
                continue
            }
        }
        if ch == "[" {
            bracketIsImageStack.append(false)
            i = cleaned.index(after: i)
            continue
        }
        if ch == "]" {
            let isImage = bracketIsImageStack.popLast() ?? false
            let afterBracket = cleaned.index(after: i)
            if afterBracket < cleaned.endIndex && cleaned[afterBracket] == "(" {
                var p = cleaned.index(after: afterBracket)
                var depth = 1
                var activeQuote: Character?
                var sawSpaceAfterDest = false
                while p < cleaned.endIndex && depth > 0 {
                    let pc = cleaned[p]
                    if pc == "\\" {
                        let next = cleaned.index(after: p)
                        p = (next < cleaned.endIndex) ? cleaned.index(after: next) : cleaned.endIndex
                        continue
                    }
                    if let q = activeQuote {
                        if pc == q {
                            activeQuote = nil
                        }
                    } else {
                        if pc.isWhitespace {
                            sawSpaceAfterDest = true
                        } else if sawSpaceAfterDest && (pc == "\"" || pc == "'") {
                            activeQuote = pc
                        } else if pc == "(" {
                            depth += 1
                        } else if pc == ")" {
                            depth -= 1
                            if depth == 0 {
                                break
                            }
                        }
                    }
                    p = cleaned.index(after: p)
                }
                if depth == 0 {
                    let inner = String(cleaned[cleaned.index(after: afterBracket)..<p])
                    if let rawDest = parseMarkdownDestination(from: inner),
                       let normalized = normalizeRelativeLinkTarget(rawDest) {
                        links.append(ExtractedMarkdownLink(path: normalized, isImage: isImage))
                    }
                    i = cleaned.index(after: p)
                    continue
                }
            }
            i = afterBracket
            continue
        }
        i = cleaned.index(after: i)
    }

    let htmlPattern = #"<(img|source|video|audio|a|link)\b[^>]*?\b(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    if let regex = try? NSRegularExpression(pattern: htmlPattern, options: [.caseInsensitive]) {
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        for match in regex.matches(in: cleaned, range: nsRange) where match.numberOfRanges >= 4 {
            let tag = Range(match.range(at: 1), in: cleaned).map { String(cleaned[$0]).lowercased() } ?? ""
            let valRange = Range(match.range(at: 2), in: cleaned) ?? Range(match.range(at: 3), in: cleaned)
            if let vr = valRange, let normalized = normalizeRelativeLinkTarget(String(cleaned[vr])) {
                links.append(ExtractedMarkdownLink(path: normalized, isImage: tag == "img"))
            }
        }
    }

    return links
}

private func extractRelativeMarkdownLinks(from markdown: String) -> [String] {
    extractRelativeLinksWithKind(from: markdown).map(\.path)
}

private func collectDiskTreeNodes(_ root: DiskTreeNode) -> [DiskTreeNode] {
    var result: [DiskTreeNode] = [root]
    var stack = Array(root.children.reversed())
    while let node = stack.popLast() {
        result.append(node)
        if !node.children.isEmpty {
            for child in node.children.reversed() {
                stack.append(child)
            }
        }
    }
    return result
}

private func parseMacSweepChecksPassedCount(from output: String) -> Int? {
    let pattern = #"MacSweepChecks summary:\s*(\d+)\s+passed,\s*(\d+)\s+failed"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          match.numberOfRanges >= 3,
          let passRange = Range(match.range(at: 1), in: output),
          let failRange = Range(match.range(at: 2), in: output),
          let passed = Int(output[passRange]),
          let failed = Int(output[failRange]),
          failed == 0 else {
        return nil
    }
    return passed
}

private let requiredScreenshotNames: [String] = [
    "01-applications-dark-en.png",
    "02-file-manager-analyzer.png",
    "03-file-manager-browser.png",
    "04-junk-cleaner.png",
    "05-resource-release-duplicates.png",
    "06-resource-release-memory.png",
    "07-startup-extensions-leftovers.png",
    "08-settings-protection-light.png",
    "09-resource-release-large-files.png",
    "10-extensions.png",
    "11-leftovers.png",
    "12-showcase-zh-dark.png",
]

let runner = E2ERunner(probeName: "E2EM4Probe")

// MARK: - Feature F10: Desensitized Demo Mode & Fixture Catalog (3 Tier 1 + 3 Tier 2 = 6 Cases)

runner.register(
    id: "f10-t1-demo-fixture-catalog-contract",
    tier: 1,
    feature: "F-10",
    name: "DemoFixtureCatalog exposes /Users/alex datasets for apps, file manager, junk, large/duplicates, and memory with zero host PII"
) {
    let catalog = DemoFixtureCatalog.default

    try E2ERunner.expect(!catalog.applications.isEmpty, "Demo applications fixture must be non-empty")
    try E2ERunner.expect(!catalog.fileBrowserEntries.isEmpty, "Demo file browser entries must be non-empty")
    try E2ERunner.expect(!catalog.diskTree.children.isEmpty, "Demo disk space analyzer tree must have children")
    try E2ERunner.expect(!catalog.junkCategories.isEmpty, "Demo junk categories must be non-empty")
    try E2ERunner.expect(!catalog.largeFiles.isEmpty, "Demo large files must be non-empty")
    try E2ERunner.expect(!catalog.duplicateGroups.isEmpty, "Demo duplicate groups must be non-empty")
    try E2ERunner.expect(catalog.memorySnapshot.totalBytes > 0, "Demo memory snapshot totalBytes must be > 0")

    let diskTreeNodes = collectDiskTreeNodes(catalog.diskTree)
    let allPaths: [String] =
        catalog.applications.map(\.url.path)
        + diskTreeNodes.map(\.url.path)
        + catalog.fileBrowserEntries.map(\.url.path)
        + catalog.junkCategories.flatMap(\.entries).map(\.url.path)
        + catalog.largeFiles.map(\.url.path)
        + catalog.duplicateGroups.flatMap(\.files).map(\.url.path)

    try E2ERunner.expect(catalog.diskTree.url.path.hasPrefix("/Users/alex"), "Demo diskTree root must live under /Users/alex")
    try E2ERunner.expect(allPaths.contains(where: { $0.hasPrefix("/Users/alex/") || $0 == "/Users/alex" }), "Demo fixtures must use /Users/alex paths")
    for path in allPaths where path.hasPrefix("/Users/") {
        let components = path.split(separator: "/").map(String.init)
        let owner = components.count >= 2 ? components[1] : ""
        try E2ERunner.expect(owner == "alex" || owner == "Shared", "Demo fixture user path must belong to /Users/alex or /Users/Shared, got: \(path)")
    }

    let realUser = NSUserName()
    let realHome = NSHomeDirectory()
    let scanner = PrivacyScanner(
        config: .hostDefault(),
        additionalAllowedAppNames: ["Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser", "Brave", "Arc"]
    )

    let allCorpusStrings: [String] =
        allPaths
        + diskTreeNodes.map(\.name)
        + catalog.applications.flatMap { [$0.name, $0.localizedName, $0.bundleID, $0.developerName ?? ""] }
        + catalog.fileBrowserEntries.map(\.name)
        + catalog.junkCategories.flatMap { [$0.title, $0.description] + $0.entries.map(\.name) }
        + catalog.largeFiles.map(\.name)
        + catalog.duplicateGroups.flatMap(\.files).map(\.name)

    for text in allCorpusStrings where !text.isEmpty {
        try E2ERunner.expect(!text.contains(realHome), "Demo fixture leaked NSHomeDirectory: \(text)")
        if realUser != "alex" {
            try E2ERunner.expect(!text.contains("/Users/\(realUser)"), "Demo fixture leaked host user path: \(text)")
        }
        let findings = scanner.scanText(text, sourceLabel: "DemoFixtureCatalog")
        try E2ERunner.expect(findings.isEmpty, "PrivacyScanner found host PII in DemoFixtureCatalog: \(findings)")
    }
}

runner.register(
    id: "f10-t1-demo-cli-export-succeeds",
    tier: 1,
    feature: "F-10",
    name: "MacSweepApp --demo-mode --export-screenshots builds and exports valid PNGs without hanging"
) {
    let sandbox = try E2ESandbox(prefix: "f10-t1-cli")
    defer { sandbox.cleanup() }

    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepApp", scratchPath: scratchPath)
    let appExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepApp failed to build: \(build.buildResult.stderr)")

    let outDir = try sandbox.createDirectory("Screenshots")
    let demoHome = sandbox.url("DemoHome").path
    let res = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--demo-mode", "--export-screenshots", outDir.path],
        environment: ["HOME": demoHome, "CFFIXED_USER_HOME": demoHome],
        timeoutSeconds: 30.0
    )

    try E2ERunner.expect(!res.timedOut, "MacSweepApp --demo-mode --export-screenshots timed out")
    try E2ERunner.expect(res.succeeded, "MacSweepApp exited with \(res.exitCode): \(res.stderr)")

    let pngs = listPNGFiles(in: outDir)
    try E2ERunner.expect(pngs.count >= requiredScreenshotNames.count, "Expected >= \(requiredScreenshotNames.count) exported PNG screenshots in \(outDir.path), got \(pngs.count)")
    let exportedNames = Set(pngs.map(\.lastPathComponent))
    for required in requiredScreenshotNames {
        try E2ERunner.expect(exportedNames.contains(required), "Missing exported demo screenshot: \(required)")
    }

    let scanner = PrivacyScanner(config: .hostDefault())
    var uniqueImages = Set<Data>()
    for png in pngs {
        let validation = scanner.validatePNG(
            at: png,
            expectedMinWidth: 1600,
            expectedMinHeight: 1000,
            requireEvenRetinaDimensions: true,
            minDistinctColors: 16,
            minLuminanceStdDev: 2.0
        )
        try E2ERunner.expect(validation.isValid, "Exported PNG validation failed for \(png.lastPathComponent): \(validation.issues)")
        uniqueImages.insert(try Data(contentsOf: png))
    }
    try E2ERunner.expect(uniqueImages.count >= requiredScreenshotNames.count, "Exported screenshots contain duplicate/identical PNG payloads")
}

runner.register(
    id: "f10-t1-demo-env-var-and-png-privacy",
    tier: 1,
    feature: "F-10",
    name: "MACSWEEP_DEMO_MODE=1 exports screenshots with zero host PII in PNG metadata or Demo sources"
) {
    let sandbox = try E2ESandbox(prefix: "f10-t1-env")
    defer { sandbox.cleanup() }

    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepApp", scratchPath: scratchPath)
    let appExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepApp failed to build: \(build.buildResult.stderr)")

    let outDir = try sandbox.createDirectory("EnvScreenshots")
    let demoHome = sandbox.url("DemoHome").path
    let res = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--export-screenshots", outDir.path],
        environment: [
            "MACSWEEP_DEMO_MODE": "1",
            "HOME": demoHome,
            "CFFIXED_USER_HOME": demoHome,
        ],
        timeoutSeconds: 30.0
    )
    try E2ERunner.expect(!res.timedOut && res.succeeded, "MACSWEEP_DEMO_MODE=1 export failed (exit \(res.exitCode), timedOut=\(res.timedOut))")

    let pngs = listPNGFiles(in: outDir)
    try E2ERunner.expect(pngs.count >= requiredScreenshotNames.count, "Expected >= \(requiredScreenshotNames.count) PNGs under MACSWEEP_DEMO_MODE=1, got \(pngs.count)")

    let pngScanner = PrivacyScanner(config: .hostDefault())
    let pngFindings = try pngScanner.scanDirectory(at: outDir, extensions: ["png"])
    try E2ERunner.expect(pngFindings.isEmpty, "Exported demo PNGs contain host PII findings: \(pngFindings)")

    let sourceScanner = PrivacyScanner(
        config: .hostDefault(),
        additionalAllowedAppNames: ["Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser", "Brave", "Arc"]
    )
    let demoCoreDir = repoRoot.appendingPathComponent("Sources/MacSweepCore/Demo")
    try E2ERunner.expect(FileManager.default.fileExists(atPath: demoCoreDir.path), "Missing Sources/MacSweepCore/Demo directory")
    let demoCoreFiles = try FileManager.default.contentsOfDirectory(at: demoCoreDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "swift" }
    try E2ERunner.expect(!demoCoreFiles.isEmpty, "Expected Swift source files in Sources/MacSweepCore/Demo")
    let demoSourceFindings = try sourceScanner.scanDirectory(at: demoCoreDir, extensions: ["swift"])
    try E2ERunner.expect(demoSourceFindings.isEmpty, "Demo core sources contain host PII: \(demoSourceFindings)")

    let exporterURL = repoRoot.appendingPathComponent("Sources/MacSweepApp/State/DemoScreenshotExporter.swift")
    try E2ERunner.expect(FileManager.default.fileExists(atPath: exporterURL.path), "Missing Sources/MacSweepApp/State/DemoScreenshotExporter.swift")
    let exporterFindings = try sourceScanner.scanFile(at: exporterURL)
    try E2ERunner.expect(exporterFindings.isEmpty, "DemoScreenshotExporter.swift contains host PII: \(exporterFindings)")
}

runner.register(
    id: "f10-t2-demo-fixture-determinism",
    tier: 2,
    feature: "F-10",
    name: "DemoFixtureCatalog produces identical deterministic datasets across repeated invocations"
) {
    let first = DemoFixtureCatalog.makeDefault()
    let second = DemoFixtureCatalog.makeDefault()

    try E2ERunner.expectEqual(first.applications, second.applications, "Demo applications must be deterministic")
    try E2ERunner.expectEqual(first.diskTree, second.diskTree, "Demo diskTree must be deterministic")
    try E2ERunner.expectEqual(first.fileBrowserEntries, second.fileBrowserEntries, "Demo fileBrowserEntries must be deterministic")
    try E2ERunner.expectEqual(first.junkCategories, second.junkCategories, "Demo junkCategories must be deterministic")
    try E2ERunner.expectEqual(first.largeFiles, second.largeFiles, "Demo largeFiles must be deterministic")
    try E2ERunner.expectEqual(first.duplicateGroups, second.duplicateGroups, "Demo duplicateGroups must be deterministic")
    try E2ERunner.expectEqual(first.memorySnapshot, second.memorySnapshot, "Demo memorySnapshot must be deterministic")
}

runner.register(
    id: "f10-t2-demo-zero-disk-side-effects-and-lang-theme",
    tier: 2,
    feature: "F-10",
    name: "Demo mode writes zero state files under HOME and renders distinct outputs for en/deepOcean vs zh/system"
) {
    let sandbox = try E2ESandbox(prefix: "f10-t2-sidefx")
    defer { sandbox.cleanup() }

    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepApp", scratchPath: scratchPath)
    let appExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepApp failed to build")

    let fakeHome = try sandbox.createDirectory("IsolatedHome")
    let appSupportMacSweep = fakeHome.appendingPathComponent("Library/Application Support/MacSweep")
    let outEn = try sandbox.createDirectory("OutEn")
    let outZh = try sandbox.createDirectory("OutZh")

    let resEn = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--demo-mode", "--demo-tab", "fileManager", "--demo-lang", "en", "--demo-theme", "deepOcean", "--export-screenshots", outEn.path],
        environment: ["HOME": fakeHome.path, "CFFIXED_USER_HOME": fakeHome.path],
        timeoutSeconds: 30.0
    )
    try E2ERunner.expect(!resEn.timedOut && resEn.succeeded, "EN/deepOcean export failed")

    let resZh = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--demo-mode", "--demo-tab", "fileManager", "--demo-lang", "zh", "--demo-theme", "system", "--export-screenshots", outZh.path],
        environment: ["HOME": fakeHome.path, "CFFIXED_USER_HOME": fakeHome.path],
        timeoutSeconds: 30.0
    )
    try E2ERunner.expect(!resZh.timedOut && resZh.succeeded, "ZH/system export failed")

    try E2ERunner.expect(!FileManager.default.fileExists(atPath: appSupportMacSweep.appendingPathComponent("preferences.json").path), "Demo mode must not write preferences.json")
    try E2ERunner.expect(!FileManager.default.fileExists(atPath: appSupportMacSweep.appendingPathComponent("history.json").path), "Demo mode must not write history.json")

    let enPNGs = listPNGFiles(in: outEn)
    let zhPNGs = listPNGFiles(in: outZh)
    try E2ERunner.expect(!enPNGs.isEmpty && !zhPNGs.isEmpty, "Both lang/theme variants must emit PNGs")
    try E2ERunner.expectEqual(enPNGs.map(\.lastPathComponent), zhPNGs.map(\.lastPathComponent), "EN and ZH exports should produce matching filename sets")

    let scanner = PrivacyScanner(config: .hostDefault())
    var anyDiffer = false
    for (enURL, zhURL) in zip(enPNGs, zhPNGs) {
        let ve = scanner.validatePNG(at: enURL, expectedMinWidth: 1600, expectedMinHeight: 1000, requireEvenRetinaDimensions: true, minDistinctColors: 16, minLuminanceStdDev: 2.0)
        let vz = scanner.validatePNG(at: zhURL, expectedMinWidth: 1600, expectedMinHeight: 1000, requireEvenRetinaDimensions: true, minDistinctColors: 16, minLuminanceStdDev: 2.0)
        try E2ERunner.expect(ve.isValid && vz.isValid, "Invalid PNG in lang/theme comparison for \(enURL.lastPathComponent)")
        if try Data(contentsOf: enURL) != Data(contentsOf: zhURL) {
            anyDiffer = true
        }
    }
    try E2ERunner.expect(anyDiffer, "EN/deepOcean and ZH/system renders should differ")
}

runner.register(
    id: "f10-t2-demo-invalid-cli-args-bounded",
    tier: 2,
    feature: "F-10",
    name: "MacSweepApp handles invalid demo CLI arguments without crashing or hanging"
) {
    let sandbox = try E2ESandbox(prefix: "f10-t2-invalid")
    defer { sandbox.cleanup() }

    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepApp", scratchPath: scratchPath)
    let appExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepApp failed to build")

    let badInvocations: [[String]] = [
        ["--demo-mode", "--demo-tab", "nonexistent_tab", "--export-screenshots", sandbox.url("Out1").path],
        ["--demo-mode", "--demo-lang", "fr", "--export-screenshots", sandbox.url("Out2").path],
        ["--demo-mode", "--demo-theme", "neon", "--export-screenshots", sandbox.url("Out3").path],
        ["--demo-mode", "--export-screenshots", "/dev/null/cannot_create_dir"],
    ]

    let isoHome = sandbox.url("Home").path
    for args in badInvocations {
        let res = ProcessProbe.runMacSweepApp(
            executableURL: appExe,
            arguments: args,
            environment: ["HOME": isoHome, "CFFIXED_USER_HOME": isoHome],
            timeoutSeconds: 15.0
        )
        try E2ERunner.expect(!res.timedOut, "Invalid args \(args) hung instead of exiting")
        try E2ERunner.expectEqual(res.terminationReason, .exit, "Invalid args \(args) crashed with uncaught signal")
        if args.last == "/dev/null/cannot_create_dir" {
            try E2ERunner.expect(!res.succeeded, "Unwritable --export-screenshots destination must exit non-zero")
        }
    }
}

// MARK: - Feature F11: Automated Retina Screenshot Pipeline & READMEs (3 Tier 1 + 3 Tier 2 = 6 Cases)

runner.register(
    id: "f11-t1-docs-screenshots-png-integrity",
    tier: 1,
    feature: "F-11",
    name: "All 12 docs/screenshots/*.png exist with valid 2x Retina dimensions and non-blank content"
) {
    let repoRoot = resolveRepoRoot()
    let screenshotsDir = repoRoot.appendingPathComponent("docs/screenshots")
    let scanner = PrivacyScanner(config: .hostDefault())

    var seenPayloads = Set<Data>()
    for name in requiredScreenshotNames {
        let pngURL = screenshotsDir.appendingPathComponent(name)
        try E2ERunner.expect(FileManager.default.fileExists(atPath: pngURL.path), "Missing screenshot: docs/screenshots/\(name)")
        let validation = scanner.validatePNG(
            at: pngURL,
            expectedMinWidth: 1600,
            expectedMinHeight: 1000,
            requireEvenRetinaDimensions: true,
            minDistinctColors: 16,
            minLuminanceStdDev: 2.0
        )
        try E2ERunner.expect(validation.isValid, "PNG validation failed for \(name): \(validation.issues)")
        seenPayloads.insert(try Data(contentsOf: pngURL))
    }
    try E2ERunner.expectEqual(seenPayloads.count, requiredScreenshotNames.count, "All 12 docs/screenshots/*.png must have distinct image contents")
}

runner.register(
    id: "f11-t1-docs-screenshots-zero-pii",
    tier: 1,
    feature: "F-11",
    name: "docs/screenshots/*.png metadata chunks contain zero host PII findings"
) {
    let repoRoot = resolveRepoRoot()
    let screenshotsDir = repoRoot.appendingPathComponent("docs/screenshots")
    try E2ERunner.expect(FileManager.default.fileExists(atPath: screenshotsDir.path), "docs/screenshots directory does not exist")

    let pngs = listPNGFiles(in: screenshotsDir)
    try E2ERunner.expect(pngs.count >= requiredScreenshotNames.count, "Expected >= \(requiredScreenshotNames.count) PNGs in docs/screenshots")

    let scanner = PrivacyScanner(config: .hostDefault())
    let findings = try scanner.scanDirectory(at: screenshotsDir, extensions: ["png"])
    try E2ERunner.expect(findings.isEmpty, "Privacy findings in docs/screenshots: \(findings)")
}

runner.register(
    id: "f11-t1-readme-links-and-images-valid",
    tier: 1,
    feature: "F-11",
    name: "All relative Markdown/HTML links and screenshot embeds in README*.md and docs/PLANNING.md resolve on disk"
) {
    let repoRoot = resolveRepoRoot()
    let docsToCheck = [
        repoRoot.appendingPathComponent("README.md"),
        repoRoot.appendingPathComponent("README_EN.md"),
        repoRoot.appendingPathComponent("README_ZH.md"),
        repoRoot.appendingPathComponent("docs/PLANNING.md"),
    ]

    let canonicalRepoRoot = SandboxBuilder.canonicalPath(for: repoRoot)

    for docURL in docsToCheck {
        let content = try String(contentsOf: docURL, encoding: .utf8)
        let baseDir = docURL.deletingLastPathComponent()
        let links = extractRelativeLinksWithKind(from: content)

        for link in links {
            let targetURL = baseDir.appendingPathComponent(link.path).standardizedFileURL
            let canonicalTarget = SandboxBuilder.canonicalPath(for: targetURL)
            let insideRepo = canonicalTarget == canonicalRepoRoot || canonicalTarget.hasPrefix(canonicalRepoRoot + "/")
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir)
            try E2ERunner.expect(exists && insideRepo, "Broken or escaping link '\(link.path)' in \(docURL.lastPathComponent) -> \(targetURL.path)")
            if link.isImage {
                try E2ERunner.expect(!isDir.boolValue, "Image link '\(link.path)' in \(docURL.lastPathComponent) points to a directory")
            }
        }

        if docURL.lastPathComponent.hasPrefix("README") {
            try E2ERunner.expect(!links.isEmpty, "Expected relative links in \(docURL.lastPathComponent)")
            try E2ERunner.expect(links.contains(where: { $0.path.contains("docs/screenshots/") }), "\(docURL.lastPathComponent) must embed docs/screenshots/ gallery link")
            try E2ERunner.expect(links.contains(where: { $0.path.contains("PLANNING.md") }), "\(docURL.lastPathComponent) must link to docs/PLANNING.md")
        }
    }
}

runner.register(
    id: "f11-t2-readme-check-count-and-tabs-accurate",
    tier: 2,
    feature: "F-11",
    name: "README*.md check counts match MacSweepChecks execution and remove stale 29-check / 4-tab claims"
) {
    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepChecks", scratchPath: scratchPath)
    let checksExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepChecks failed to build: \(build.buildResult.stderr)")

    let run = ProcessProbe.runMacSweepChecks(executableURL: checksExe, timeoutSeconds: 60.0)
    try E2ERunner.expect(run.succeeded, "MacSweepChecks failed: \(run.stderr)")

    let passedCount = try E2ERunner.expectNotNil(
        parseMacSweepChecksPassedCount(from: run.stdout),
        "Could not parse MacSweepChecks passed count from output"
    )
    try E2ERunner.expect(passedCount >= 78, "Expected >= 78 MacSweepChecks passed, got \(passedCount)")

    let countPattern = "(?<![0-9A-Za-z_])\(passedCount)(?![0-9A-Za-z_])"
    let countRegex = try NSRegularExpression(pattern: countPattern)
    let stalePattern = #"(?i)(?<![0-9A-Za-z_.])(?:29\s+(?:sandbox\b|(?:[a-z]+\s+){0,2}(?:checks?|tests?))|29\s*项|all\s+29|4\s+(?:[a-z]+\s+){0,2}tabs?|4\s*大功能页签)(?![0-9A-Za-z_])"#
    let staleRegex = try NSRegularExpression(pattern: stalePattern)

    for fileName in ["README.md", "README_EN.md", "README_ZH.md"] {
        let content = try String(contentsOf: repoRoot.appendingPathComponent(fileName), encoding: .utf8)
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        if let match = staleRegex.firstMatch(in: content, range: nsRange),
           let swiftRange = Range(match.range, in: content) {
            throw E2EAssertionFailure("\(fileName) contains stale 29-check or 4-tab phrasing: '\(content[swiftRange])'")
        }
        try E2ERunner.expect(countRegex.firstMatch(in: content, range: nsRange) != nil, "\(fileName) should state exact MacSweepChecks count \(passedCount)")
    }
}

runner.register(
    id: "f11-t2-readme-docs-zero-host-pii",
    tier: 2,
    feature: "F-11",
    name: "README*.md and docs/PLANNING.md contain zero host username, home path, or personal app leaks"
) {
    let repoRoot = resolveRepoRoot()
    let scanner = PrivacyScanner(
        config: .hostDefault(),
        additionalAllowedAppNames: [
            "Google Chrome",
            "Firefox",
            "Microsoft Edge",
            "Brave Browser",
            "Brave",
            "Arc",
            "Docker",
            "Visual Studio Code",
            "Simulator",
            "Homebrew",
        ]
    )
    let files = [
        repoRoot.appendingPathComponent("README.md"),
        repoRoot.appendingPathComponent("README_EN.md"),
        repoRoot.appendingPathComponent("README_ZH.md"),
        repoRoot.appendingPathComponent("docs/PLANNING.md"),
    ]
    for fileURL in files {
        let findings = try scanner.scanFile(at: fileURL)
        try E2ERunner.expect(findings.isEmpty, "Privacy leak in \(fileURL.lastPathComponent): \(findings)")
    }
}

runner.register(
    id: "f11-t2-png-export-reproducible-nonempty",
    tier: 2,
    feature: "F-11",
    name: "Repeated --demo-mode --export-screenshots runs produce reproducible filenames and valid Retina PNGs"
) {
    let sandbox = try E2ESandbox(prefix: "f11-t2-repro")
    defer { sandbox.cleanup() }

    let repoRoot = resolveRepoRoot()
    let scratchPath = resolveAppScratchPath(repoRoot: repoRoot)
    let build = ProcessProbe.buildProduct(repoRoot: repoRoot, product: "MacSweepApp", scratchPath: scratchPath)
    let appExe = try E2ERunner.expectNotNil(build.executableURL, "MacSweepApp failed to build")

    let outA = sandbox.url("Nested/OutA")
    let outB = sandbox.url("Nested/OutB")
    let fakeHome = sandbox.url("Home").path

    let resA = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--demo-mode", "--export-screenshots", outA.path],
        environment: ["HOME": fakeHome, "CFFIXED_USER_HOME": fakeHome],
        timeoutSeconds: 30.0
    )
    let resB = ProcessProbe.runMacSweepApp(
        executableURL: appExe,
        arguments: ["--demo-mode", "--export-screenshots", outB.path],
        environment: ["HOME": fakeHome, "CFFIXED_USER_HOME": fakeHome],
        timeoutSeconds: 30.0
    )

    try E2ERunner.expect(!resA.timedOut && resA.succeeded, "Run A failed")
    try E2ERunner.expect(!resB.timedOut && resB.succeeded, "Run B failed")

    let pngsA = listPNGFiles(in: outA)
    let pngsB = listPNGFiles(in: outB)
    try E2ERunner.expect(pngsA.count >= requiredScreenshotNames.count, "Expected >= \(requiredScreenshotNames.count) PNGs in OutA, got \(pngsA.count)")
    try E2ERunner.expectEqual(pngsA.map(\.lastPathComponent), pngsB.map(\.lastPathComponent), "Exported PNG filename sets must match across runs")

    let scanner = PrivacyScanner(config: .hostDefault())
    for (a, b) in zip(pngsA, pngsB) {
        let va = scanner.validatePNG(at: a, expectedMinWidth: 1600, expectedMinHeight: 1000, requireEvenRetinaDimensions: true, minDistinctColors: 16, minLuminanceStdDev: 2.0)
        let vb = scanner.validatePNG(at: b, expectedMinWidth: 1600, expectedMinHeight: 1000, requireEvenRetinaDimensions: true, minDistinctColors: 16, minLuminanceStdDev: 2.0)
        try E2ERunner.expect(va.isValid && vb.isValid, "PNG validation failed for \(a.lastPathComponent)")
        try E2ERunner.expectEqual(va.pixelWidth, vb.pixelWidth)
        try E2ERunner.expectEqual(va.pixelHeight, vb.pixelHeight)
    }
}

await runner.runAndExit()

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import zlib

public struct PrivacyFinding: Sendable, Equatable {
    public let rule: String
    public let matchedValue: String
    public let location: String
    public let excerpt: String

    public init(rule: String, matchedValue: String, location: String, excerpt: String) {
        self.rule = rule
        self.matchedValue = matchedValue
        self.location = location
        self.excerpt = excerpt
    }
}

public struct PrivacyScanConfig: Sendable {
    public let userName: String
    public let fullUserName: String
    public let homeDirectory: String
    public let canonicalHomeDirectory: String
    public let installedAppNames: Set<String>
    public let excludedAppNames: Set<String>

    public static let defaultExcludedAppNames: Set<String> = [
        "macsweep",
        "safari",
        "pages",
        "numbers",
        "keynote",
        "mail",
        "notes",
        "preview",
        "finder",
        "terminal",
        "xcode",
        "shortcuts",
        "photos",
        "calendar",
        "reminders",
        "contacts",
        "messages",
        "facetime",
        "app store",
        "system settings",
        "activity monitor",
        "textedit",
        "music",
        "podcasts",
        "tv",
        "books",
        "maps",
        "weather",
        "stocks",
        "home",
        "news",
        "voice memos",
        "freeform",
        "journal",
        "passwords",
        "image playground",
        "testflight",
        "calculator",
        "chess",
        "clock",
        "dictionary",
        "font book",
        "image capture",
        "launchpad",
        "migration assistant",
        "photo booth",
        "quicktime player",
        "screenshot",
        "siri",
        "stickies",
        "system information",
        "time machine",
        "voiceover utility",
    ]

    public init(
        userName: String,
        fullUserName: String,
        homeDirectory: String,
        canonicalHomeDirectory: String,
        installedAppNames: Set<String>,
        excludedAppNames: Set<String> = defaultExcludedAppNames
    ) {
        self.userName = userName
        self.fullUserName = fullUserName
        self.homeDirectory = homeDirectory
        self.canonicalHomeDirectory = canonicalHomeDirectory
        self.installedAppNames = installedAppNames
        self.excludedAppNames = Set(excludedAppNames.map { $0.lowercased() })
    }

    public static func hostDefault() -> PrivacyScanConfig {
        let user = NSUserName()
        let fullName = NSFullUserName()
        let home = NSHomeDirectory()
        let canonicalHome = SandboxBuilder.canonicalPath(forPath: home)

        let fm = FileManager.default
        let appDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true),
        ]

        var discoveredApps = Set<String>()
        for dir in appDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items where item.pathExtension.lowercased() == "app" {
                let stem = item.deletingPathExtension().lastPathComponent
                if !stem.isEmpty {
                    discoveredApps.insert(stem)
                }
            }
        }

        return PrivacyScanConfig(
            userName: user,
            fullUserName: fullName,
            homeDirectory: home,
            canonicalHomeDirectory: canonicalHome,
            installedAppNames: discoveredApps
        )
    }
}

public struct PNGValidationResult: Sendable, Equatable {
    public let url: URL
    public let hasPNGMagic: Bool
    public let hasIHDR: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let sipsWidth: Int?
    public let sipsHeight: Int?
    public let sampledDistinctColors: Int
    public let luminanceStdDev: Double
    public let isValid: Bool
    public let issues: [String]

    public init(
        url: URL,
        hasPNGMagic: Bool,
        hasIHDR: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        sipsWidth: Int?,
        sipsHeight: Int?,
        sampledDistinctColors: Int,
        luminanceStdDev: Double,
        isValid: Bool,
        issues: [String]
    ) {
        self.url = url
        self.hasPNGMagic = hasPNGMagic
        self.hasIHDR = hasIHDR
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sipsWidth = sipsWidth
        self.sipsHeight = sipsHeight
        self.sampledDistinctColors = sampledDistinctColors
        self.luminanceStdDev = luminanceStdDev
        self.isValid = isValid
        self.issues = issues
    }
}

public struct PrivacyScanner: Sendable {
    public let config: PrivacyScanConfig
    public let additionalAllowedAppNames: Set<String>

    public init(
        config: PrivacyScanConfig = .hostDefault(),
        additionalAllowedAppNames: Set<String> = []
    ) {
        self.config = config
        self.additionalAllowedAppNames = Set(additionalAllowedAppNames.map { $0.lowercased() })
    }

    public func scanText(_ text: String, sourceLabel: String = "<string>") -> [PrivacyFinding] {
        guard !text.isEmpty else { return [] }
        var nativeText = text
        nativeText.makeContiguousUTF8()
        var findings: [PrivacyFinding] = []
        var dedup = Set<String>()
        let index = TextSearchIndex(text: nativeText)

        func record(rule: String, value: String, range: Range<String.Index>) {
            let key = "\(rule)|\(value.lowercased())|\(sourceLabel)"
            guard dedup.insert(key).inserted else { return }
            findings.append(PrivacyFinding(
                rule: rule,
                matchedValue: value,
                location: sourceLabel,
                excerpt: makeExcerpt(in: nativeText, around: range)
            ))
        }

        // 1. Home directory & /Users/<username> path variants
        var homeVariants: [String] = []
        if !config.homeDirectory.isEmpty {
            homeVariants.append(config.homeDirectory)
            if let encoded = config.homeDirectory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                homeVariants.append("file://" + encoded)
            }
        }
        if !config.canonicalHomeDirectory.isEmpty && config.canonicalHomeDirectory != config.homeDirectory {
            homeVariants.append(config.canonicalHomeDirectory)
        }
        for variant in Set(homeVariants) where !variant.isEmpty {
            if let range = index.findSubstringMatch(needle: variant, caseSensitive: false) {
                record(rule: "home_dir", value: variant, range: range)
            }
        }

        if !config.userName.isEmpty {
            if index.hasUsersSlash {
                for userPath in ["/Users/\(config.userName)", "/private/Users/\(config.userName)"] {
                    if let range = index.findSubstringMatch(needle: userPath, caseSensitive: false) {
                        record(rule: "home_dir", value: userPath, range: range)
                    }
                }
            }

            // Username matching
            if config.userName.count >= 5 {
                if let range = index.findSubstringMatch(needle: config.userName, caseSensitive: false) {
                    record(rule: "username", value: config.userName, range: range)
                }
            } else {
                if let range = index.findBoundaryMatch(needle: config.userName, caseSensitive: false) {
                    record(rule: "username", value: config.userName, range: range)
                }
            }
        }

        // 2. Full user name
        let trimmedFullName = config.fullUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFullNameASCII = trimmedFullName.unicodeScalars.allSatisfy(\.isASCII)
        let minFullNameChars = isFullNameASCII ? 4 : 2
        if trimmedFullName.count >= minFullNameChars && trimmedFullName.lowercased() != config.userName.lowercased() {
            if isFullNameASCII {
                if let range = index.findBoundaryMatch(needle: trimmedFullName, caseSensitive: false) {
                    record(rule: "full_name", value: trimmedFullName, range: range)
                }
            } else {
                // Non-ASCII names (e.g. CJK) match directly without ASCII identifier-boundary suppression.
                if let range = index.findSubstringMatch(needle: trimmedFullName, caseSensitive: false) {
                    record(rule: "full_name", value: trimmedFullName, range: range)
                }
            }
        }

        // 3. Installed app bundle paths & stems
        let hasDotApp = index.hasDotApp
        let hasAppsSlash = hasDotApp && index.hasApplicationsSlash
        let hasTildeAppsSlash = hasDotApp && index.hasTildeApplicationsSlash
        let hasUsersAppsSlash = hasDotApp && index.hasUsersSlash

        for appName in config.installedAppNames.sorted() {
            let lowerApp = appName.lowercased()
            if lowerApp == "macsweep" || additionalAllowedAppNames.contains(lowerApp) {
                continue
            }

            if hasAppsSlash {
                let p = "/Applications/\(appName).app"
                if let range = index.findSubstringMatch(needle: p, caseSensitive: false) {
                    record(rule: "installed_app_path", value: p, range: range)
                }
            }
            if hasTildeAppsSlash {
                let p = "~/Applications/\(appName).app"
                if let range = index.findSubstringMatch(needle: p, caseSensitive: false) {
                    record(rule: "installed_app_path", value: p, range: range)
                }
            }
            if hasUsersAppsSlash {
                let p = "/Users/\(config.userName)/Applications/\(appName).app"
                if let range = index.findSubstringMatch(needle: p, caseSensitive: false) {
                    record(rule: "installed_app_path", value: p, range: range)
                }
            }

            if config.excludedAppNames.contains(lowerApp) {
                continue
            }

            if hasDotApp {
                let bundleToken = "\(appName).app"
                if let range = index.findSubstringMatch(needle: bundleToken, caseSensitive: false) {
                    record(rule: "installed_app_name", value: bundleToken, range: range)
                    continue
                }
            }

            let isPureASCII = appName.unicodeScalars.allSatisfy(\.isASCII)
            if isPureASCII && appName.count <= 4 {
                // Short ASCII stems (e.g. "Sip", "Loon", "Keka") require exact-case whole-word match
                // so normal words like "sips" or "SIP" do not false-positive.
                if let range = index.findBoundaryMatch(needle: appName, caseSensitive: true) {
                    record(rule: "installed_app_name", value: appName, range: range)
                }
            } else if isPureASCII {
                if let range = index.findBoundaryMatch(needle: appName, caseSensitive: false) {
                    record(rule: "installed_app_name", value: appName, range: range)
                }
            } else {
                // Non-ASCII names (e.g. CJK app names) match directly.
                if let range = index.findSubstringMatch(needle: appName, caseSensitive: true) {
                    record(rule: "installed_app_name", value: appName, range: range)
                }
            }
        }

        return findings
    }

    public func scanFile(at url: URL, maxBytes: Int = 8 * 1024 * 1024) throws -> [PrivacyFinding] {
        let data = try readRegularFileBounded(at: url, maxBytes: maxBytes)
        let ext = url.pathExtension.lowercased()
        let isPNG = (ext == "png") || data.starts(with: Self.pngMagic)
        let textExtensions: Set<String> = ["md", "json", "txt", "sh", "swift", "plist", "html", "svg", "xml", "yml", "yaml"]

        if isPNG {
            return scanPNGData(data, sourceLabel: url.path).findings
        }

        if textExtensions.contains(ext), let text = String(data: data, encoding: .utf8) {
            return scanText(text, sourceLabel: url.path)
        }

        // Binary file: extract printable UTF-8/ASCII runs >= 4 bytes.
        let extracted = extractPrintableRuns(from: data, minLength: 4)
        guard !extracted.isEmpty else { return [] }
        return scanText(extracted, sourceLabel: url.path)
    }

    public func scanDirectory(
        at root: URL,
        extensions: Set<String>? = nil,
        skipHiddenFiles: Bool = false
    ) throws -> [PrivacyFinding] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if skipHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        let lowerExts = extensions.map { Set($0.map { $0.lowercased() }) }
        var allFindings: [PrivacyFinding] = []
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else {
                continue
            }
            let ext = itemURL.pathExtension.lowercased()
            if let lowerExts, !lowerExts.contains(ext) {
                continue
            }
            let maxBytes = (ext == "png") ? 32 * 1024 * 1024 : 8 * 1024 * 1024
            do {
                allFindings.append(contentsOf: try scanFile(at: itemURL, maxBytes: maxBytes))
            } catch SandboxBuilderError.posixFailure(operation: "oversized", path: _, errno: EFBIG) {
                let sizeStr = fileByteSize(at: itemURL).map { "\($0)" } ?? ">\(maxBytes)"
                allFindings.append(PrivacyFinding(
                    rule: "oversized_file",
                    matchedValue: sizeStr,
                    location: itemURL.path,
                    excerpt: "Skipped oversized file exceeding \(maxBytes) bytes"
                ))
            } catch let posixErr as POSIXError where posixErr.code == .EFBIG {
                let sizeStr = fileByteSize(at: itemURL).map { "\($0)" } ?? ">\(maxBytes)"
                allFindings.append(PrivacyFinding(
                    rule: "oversized_file",
                    matchedValue: sizeStr,
                    location: itemURL.path,
                    excerpt: "Skipped oversized file exceeding \(maxBytes) bytes"
                ))
            } catch let cocoaErr as CocoaError where cocoaErr.code == .fileReadTooLarge {
                let sizeStr = fileByteSize(at: itemURL).map { "\($0)" } ?? ">\(maxBytes)"
                allFindings.append(PrivacyFinding(
                    rule: "oversized_file",
                    matchedValue: sizeStr,
                    location: itemURL.path,
                    excerpt: "Skipped oversized file exceeding \(maxBytes) bytes"
                ))
            }
        }
        return allFindings
    }

    public func validatePNG(
        at url: URL,
        expectedMinWidth: Int = 1600,
        expectedMinHeight: Int = 1000,
        requireEvenRetinaDimensions: Bool = true,
        minDistinctColors: Int = 16,
        minLuminanceStdDev: Double = 2.0
    ) -> PNGValidationResult {
        var issues: [String] = []

        let data: Data
        do {
            data = try readRegularFileBounded(at: url, maxBytes: 32 * 1024 * 1024)
        } catch {
            return PNGValidationResult(
                url: url,
                hasPNGMagic: false,
                hasIHDR: false,
                pixelWidth: 0,
                pixelHeight: 0,
                sipsWidth: nil,
                sipsHeight: nil,
                sampledDistinctColors: 0,
                luminanceStdDev: 0,
                isValid: false,
                issues: ["Failed to read PNG file: \(error)"]
            )
        }

        let hasMagic = data.count >= 8 && data.starts(with: Self.pngMagic)
        if !hasMagic {
            issues.append("Missing 8-byte PNG magic signature")
        }

        let ihdrBytes: [UInt8] = [0x49, 0x48, 0x44, 0x52] // "IHDR"
        let hasIHDR = data.count >= 16 && Array(data[12..<16]) == ihdrBytes
        if !hasIHDR {
            issues.append("Missing IHDR chunk at bytes 12..<16")
        }

        // Cross-check dimensions via /usr/bin/sips
        let sipsResult = ProcessProbe.sips(arguments: ["-g", "pixelWidth", "-g", "pixelHeight", url.path])
        let sipsWidth = parseSipsDimension(key: "pixelWidth", from: sipsResult.stdout)
        let sipsHeight = parseSipsDimension(key: "pixelHeight", from: sipsResult.stdout)
        if !sipsResult.succeeded || sipsWidth == nil || sipsHeight == nil {
            issues.append("/usr/bin/sips failed to report pixelWidth/pixelHeight")
        }

        // Decode with ImageIO + CoreGraphics
        var cgWidth = 0
        var cgHeight = 0
        var distinctColors = 0
        var lumaStdDev = 0.0

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            cgWidth = cgImage.width
            cgHeight = cgImage.height

            if let sw = sipsWidth, sw != cgWidth {
                issues.append("sips pixelWidth (\(sw)) != CGImage width (\(cgWidth))")
            }
            if let sh = sipsHeight, sh != cgHeight {
                issues.append("sips pixelHeight (\(sh)) != CGImage height (\(cgHeight))")
            }
            if cgWidth < expectedMinWidth {
                issues.append("Width \(cgWidth) < expectedMinWidth \(expectedMinWidth)")
            }
            if cgHeight < expectedMinHeight {
                issues.append("Height \(cgHeight) < expectedMinHeight \(expectedMinHeight)")
            }
            if requireEvenRetinaDimensions && ((cgWidth % 2 != 0) || (cgHeight % 2 != 0)) {
                issues.append("Dimensions \(cgWidth)x\(cgHeight) are not even 2x Retina multiples")
            }

            let stats = computeSampledPixelStats(cgImage: cgImage, sampleSide: 64)
            distinctColors = stats.distinctColors
            lumaStdDev = stats.luminanceStdDev
            if distinctColors < minDistinctColors {
                issues.append("Sampled distinct colors \(distinctColors) < \(minDistinctColors) (likely blank/solid)")
            }
            if lumaStdDev < minLuminanceStdDev {
                issues.append("Sampled luminance stddev \(String(format: "%.2f", lumaStdDev)) < \(minLuminanceStdDev)")
            }
        } else {
            issues.append("CGImageSource failed to decode PNG image")
        }

        let pngScan = scanPNGData(data, sourceLabel: url.path)
        for chunkIssue in pngScan.issues {
            issues.append(chunkIssue)
        }
        if !pngScan.findings.isEmpty {
            let summary = pngScan.findings.map { "\($0.rule):\($0.matchedValue)" }.joined(separator: ", ")
            issues.append("Privacy leak in PNG metadata: \(summary)")
        }

        return PNGValidationResult(
            url: url,
            hasPNGMagic: hasMagic,
            hasIHDR: hasIHDR,
            pixelWidth: cgWidth,
            pixelHeight: cgHeight,
            sipsWidth: sipsWidth,
            sipsHeight: sipsHeight,
            sampledDistinctColors: distinctColors,
            luminanceStdDev: lumaStdDev,
            isValid: issues.isEmpty,
            issues: issues
        )
    }

    // MARK: - Helpers

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let skippedPNGChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND",
        "pHYs", "gAMA", "cHRM", "sRGB", "sBIT", "bKGD", "hIST", "tRNS", "sPLT",
    ]
    private static let maxDecompressedPNGChunkBytes = 16 * 1024 * 1024
    private static let maxTotalDecompressedPNGBytes = 32 * 1024 * 1024

    private func scanPNGData(_ data: Data, sourceLabel: String) -> (findings: [PrivacyFinding], issues: [String]) {
        let parsed = parsePNGMetadata(from: data)
        guard !parsed.metadataText.isEmpty else {
            return ([], parsed.issues)
        }
        let rawFindings = scanText(parsed.metadataText, sourceLabel: sourceLabel)
        let mappedFindings = rawFindings.map {
            PrivacyFinding(
                rule: "png_metadata",
                matchedValue: $0.matchedValue,
                location: $0.location,
                excerpt: $0.excerpt
            )
        }
        return (mappedFindings, parsed.issues)
    }

    private func parsePNGMetadata(from data: Data) -> (metadataText: String, issues: [String]) {
        guard data.starts(with: Self.pngMagic) else {
            // Safe fallback ONLY for non-PNG data (never scan raw IDAT bytes of a PNG).
            let fallback = extractPrintableRuns(from: data, minLength: 4)
            return (fallback, [])
        }

        let totalCount = data.count
        var offset = 8
        var textPieces: [String] = []
        var issues: [String] = []
        var totalDecompressedBytes = 0
        var cumulativeBudgetExceeded = false

        func decompressChunkPayload(_ compressed: Data, chunkDescription: String) -> Data? {
            guard !compressed.isEmpty else { return Data() }
            if cumulativeBudgetExceeded {
                return nil
            }
            let remainingBudget = Self.maxTotalDecompressedPNGBytes - totalDecompressedBytes
            if remainingBudget <= 0 {
                cumulativeBudgetExceeded = true
                issues.append("Cumulative decompressed PNG metadata exceeds \(Self.maxTotalDecompressedPNGBytes) bytes")
                return nil
            }
            let effectiveCap = min(Self.maxDecompressedPNGChunkBytes, remainingBudget)
            switch decompressZlib(compressed, maxOutputBytes: effectiveCap) {
            case .success(let decompressed):
                totalDecompressedBytes += decompressed.count
                return decompressed
            case .failure(let reason):
                if remainingBudget < Self.maxDecompressedPNGChunkBytes
                    && reason == "decompressed output exceeds \(effectiveCap) bytes" {
                    cumulativeBudgetExceeded = true
                    issues.append("Cumulative decompressed PNG metadata exceeds \(Self.maxTotalDecompressedPNGBytes) bytes")
                } else {
                    issues.append("Failed to decompress PNG \(chunkDescription): \(reason)")
                }
                return nil
            }
        }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            while offset < totalCount {
                if offset + 12 > totalCount {
                    issues.append("Malformed PNG chunk header at offset \(offset): \(totalCount - offset) trailing bytes")
                    break
                }

                let lengthUInt32 = (UInt32(base[offset]) << 24)
                    | (UInt32(base[offset + 1]) << 16)
                    | (UInt32(base[offset + 2]) << 8)
                    | UInt32(base[offset + 3])

                let typeRange = (offset + 4)..<(offset + 8)
                let chunkType = String(bytes: data[typeRange], encoding: .isoLatin1) ?? "????"

                let remainingAfterHeaderAndCRC = totalCount - offset - 12
                if lengthUInt32 > 0x7FFF_FFFF || Int(lengthUInt32) > remainingAfterHeaderAndCRC {
                    issues.append("Truncated or malformed PNG chunk '\(chunkType)' at offset \(offset)")
                    if !Self.skippedPNGChunks.contains(chunkType), offset + 8 < totalCount {
                        let partialPayload = Data(data[(offset + 8)..<totalCount])
                        let runs = extractPrintableRuns(from: partialPayload, minLength: 4)
                        if !runs.isEmpty {
                            textPieces.append(runs)
                        }
                    }
                    break
                }

                let length = Int(lengthUInt32)
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + length
                offset = payloadEnd + 4

                if Self.skippedPNGChunks.contains(chunkType) {
                    if chunkType == "IEND" {
                        break
                    }
                    continue
                }

                let payload = Data(data[payloadStart..<payloadEnd])

                switch chunkType {
                case "tEXt":
                    if let nullIdx = payload.firstIndex(of: 0x00) {
                        let keywordData = Data(payload[..<nullIdx])
                        let textData = Data(payload[payload.index(after: nullIdx)...])
                        let keyword = decodePNGText(keywordData)
                        let text = decodePNGText(textData)
                        if !keyword.isEmpty { textPieces.append(keyword) }
                        if !text.isEmpty { textPieces.append(text) }
                    } else {
                        let text = decodePNGText(payload)
                        if !text.isEmpty { textPieces.append(text) }
                    }

                case "iTXt":
                    if let kNull = payload.firstIndex(of: 0x00), kNull + 3 <= payload.count {
                        let keyword = decodePNGText(Data(payload[..<kNull]))
                        let compressionFlag = payload[kNull + 1]
                        let compressionMethod = payload[kNull + 2]
                        let afterHeader = kNull + 3
                        if let langNull = payload[afterHeader...].firstIndex(of: 0x00) {
                            let languageTag = decodePNGText(Data(payload[afterHeader..<langNull]))
                            let afterLang = langNull + 1
                            if let transNull = payload[afterLang...].firstIndex(of: 0x00) {
                                let translatedKeyword = decodePNGText(Data(payload[afterLang..<transNull]))
                                let textData = Data(payload[(transNull + 1)...])
                                if !keyword.isEmpty { textPieces.append(keyword) }
                                if !languageTag.isEmpty { textPieces.append(languageTag) }
                                if !translatedKeyword.isEmpty { textPieces.append(translatedKeyword) }

                                if compressionFlag == 0 {
                                    let decoded = decodePNGText(textData)
                                    if !decoded.isEmpty { textPieces.append(decoded) }
                                } else if compressionFlag == 1 {
                                    if compressionMethod == 0 {
                                        if let decompressed = decompressChunkPayload(
                                            textData,
                                            chunkDescription: "iTXt chunk '\(keyword)'"
                                        ) {
                                            let decoded = decodePNGText(decompressed)
                                            if !decoded.isEmpty { textPieces.append(decoded) }
                                        }
                                    } else {
                                        issues.append("Unsupported PNG iTXt compressionMethod \(compressionMethod)")
                                    }
                                } else {
                                    issues.append("Invalid PNG iTXt compressionFlag \(compressionFlag)")
                                }
                            } else {
                                issues.append("Malformed PNG iTXt chunk '\(keyword)': missing translatedKeyword NUL")
                                let runs = extractPrintableRuns(from: payload, minLength: 4)
                                if !runs.isEmpty { textPieces.append(runs) }
                            }
                        } else {
                            issues.append("Malformed PNG iTXt chunk '\(keyword)': missing languageTag NUL")
                            let runs = extractPrintableRuns(from: payload, minLength: 4)
                            if !runs.isEmpty { textPieces.append(runs) }
                        }
                    } else {
                        issues.append("Malformed PNG iTXt chunk structure")
                        let runs = extractPrintableRuns(from: payload, minLength: 4)
                        if !runs.isEmpty { textPieces.append(runs) }
                    }

                case "zTXt":
                    if let kNull = payload.firstIndex(of: 0x00), kNull + 2 <= payload.count {
                        let keyword = decodePNGText(Data(payload[..<kNull]))
                        let compressionMethod = payload[kNull + 1]
                        let compressedData = Data(payload[(kNull + 2)...])
                        if !keyword.isEmpty { textPieces.append(keyword) }

                        if compressionMethod == 0 {
                            if let decompressed = decompressChunkPayload(
                                compressedData,
                                chunkDescription: "zTXt chunk '\(keyword)'"
                            ) {
                                let decoded = decodePNGText(decompressed)
                                if !decoded.isEmpty { textPieces.append(decoded) }
                            }
                        } else {
                            issues.append("Unsupported PNG zTXt compressionMethod \(compressionMethod)")
                        }
                    } else {
                        issues.append("Malformed PNG zTXt chunk structure")
                        let runs = extractPrintableRuns(from: payload, minLength: 4)
                        if !runs.isEmpty { textPieces.append(runs) }
                    }

                case "iCCP":
                    // ISO/IEC 15948 §11.3.3.3: <profileName>\0<compressionMethod><zlib-compressed ICC profile>
                    if let kNull = payload.firstIndex(of: 0x00), kNull + 2 <= payload.count {
                        let profileName = decodePNGText(Data(payload[..<kNull]))
                        let compressionMethod = payload[kNull + 1]
                        let compressedProfile = Data(payload[(kNull + 2)...])
                        if !profileName.isEmpty { textPieces.append(profileName) }

                        if compressionMethod == 0 {
                            if let decompressed = decompressChunkPayload(
                                compressedProfile,
                                chunkDescription: "iCCP chunk '\(profileName)'"
                            ) {
                                let runs = extractPrintableRuns(from: decompressed, minLength: 4)
                                if !runs.isEmpty { textPieces.append(runs) }
                                let utf16Runs = extractICCUTF16BEStrings(from: decompressed)
                                if !utf16Runs.isEmpty { textPieces.append(utf16Runs) }
                            }
                        } else {
                            issues.append("Unsupported PNG iCCP compressionMethod \(compressionMethod)")
                            let runs = extractPrintableRuns(from: payload, minLength: 4)
                            if !runs.isEmpty { textPieces.append(runs) }
                        }
                    } else {
                        issues.append("Malformed PNG iCCP chunk structure")
                        let runs = extractPrintableRuns(from: payload, minLength: 4)
                        if !runs.isEmpty { textPieces.append(runs) }
                    }

                default:
                    // eXIf and any other/unknown ancillary chunks
                    let runs = extractPrintableRuns(from: payload, minLength: 4)
                    if !runs.isEmpty { textPieces.append(runs) }
                }
            }
        }

        return (textPieces.joined(separator: "\n"), issues)
    }

    private func decodePNGText(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        var parts: [String] = []
        let runs = extractPrintableRuns(from: data, minLength: 4)
        if !runs.isEmpty {
            parts.append(runs)
        }
        if let latin1 = String(data: data, encoding: .isoLatin1), !latin1.isEmpty {
            parts.append(latin1)
        }
        return parts.joined(separator: "\n")
    }

    private enum ZlibDecompressResult {
        case success(Data)
        case failure(String)
    }

    private func decompressZlib(_ compressed: Data, maxOutputBytes: Int) -> ZlibDecompressResult {
        guard !compressed.isEmpty else { return .success(Data()) }

        return compressed.withUnsafeBytes { rawInput -> ZlibDecompressResult in
            guard let basePtr = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                return .success(Data())
            }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer(mutating: basePtr)
            stream.avail_in = uInt(compressed.count)

            let initStatus = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else {
                return .failure("inflateInit_ failed (\(initStatus))")
            }
            defer { inflateEnd(&stream) }

            var output = Data()
            let chunkSize = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let remaining = maxOutputBytes - output.count
                if remaining == 0 {
                    var probeByte: UInt8 = 0
                    let probeStatus = withUnsafeMutablePointer(to: &probeByte) { ptr -> Int32 in
                        stream.next_out = ptr
                        stream.avail_out = 1
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    if probeStatus == Z_STREAM_END && stream.avail_out == 1 {
                        return .success(output)
                    }
                    return .failure("decompressed output exceeds \(maxOutputBytes) bytes")
                }

                let stepCap = min(chunkSize, remaining)
                let status: Int32 = buffer.withUnsafeMutableBytes { outRaw in
                    guard let outPtr = outRaw.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outPtr
                    stream.avail_out = uInt(stepCap)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = stepCap - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[..<produced])
                }

                if status == Z_STREAM_END {
                    return .success(output)
                }
                if status != Z_OK {
                    return .failure("zlib inflate error (\(status))")
                }
            }
        }
    }

    private func readRegularFileBounded(at url: URL, maxBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw SandboxBuilderError.posixFailure(operation: "open", path: url.path, errno: errno)
        }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw SandboxBuilderError.posixFailure(operation: "fstat", path: url.path, errno: errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw SandboxBuilderError.posixFailure(operation: "not_regular_file", path: url.path, errno: EFTYPE)
        }
        guard st.st_size <= Int64(maxBytes) else {
            throw SandboxBuilderError.posixFailure(operation: "oversized", path: url.path, errno: EFBIG)
        }

        var data = Data()
        data.reserveCapacity(Int(max(0, st.st_size)))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                if data.count + n > maxBytes {
                    throw SandboxBuilderError.posixFailure(operation: "oversized", path: url.path, errno: EFBIG)
                }
                data.append(contentsOf: buffer[..<n])
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                throw SandboxBuilderError.posixFailure(operation: "read", path: url.path, errno: errno)
            }
        }
        return data
    }

    private func fileByteSize(at url: URL) -> Int64? {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return nil }
        return st.st_size
    }

    private final class TextSearchIndex {
        private struct NFCChunk {
            let rawStart: String.Index
            let rawEnd: String.Index
            let nfcByteStart: Int
            let nfcLowerByteStart: Int
        }

        private enum LowerMapResult {
            case matched(Range<String.Index>)
            case falseHit
            case fallbackNeeded
        }

        let text: String
        let textUTF8: [UInt8]
        let lowerText: String
        let lowerUTF8: [UInt8]
        let textIsASCII: Bool
        let sameUTF8Length: Bool
        let hasDotApp: Bool
        let hasApplicationsSlash: Bool
        let hasTildeApplicationsSlash: Bool
        let hasUsersSlash: Bool

        private var presentRawCache = [Int8](repeating: -1, count: 256)
        private var presentLowerCache = [Int8](repeating: -1, count: 256)

        private var lowerCheckpointsBuilt = false
        private var lowerCheckpoints: [(raw: Int, lower: Int)] = []
        private var lowerCheckpointsValid = false

        private var nfcIndexBuilt = false
        private var nfcText = ""
        private var nfcUTF8: [UInt8] = []
        private var nfcLowerText = ""
        private var nfcLowerUTF8: [UInt8] = []
        private var nfcChunks: [NFCChunk] = []
        private var presentNFCCache = [Int8](repeating: -1, count: 256)
        private var presentNFCLowerCache = [Int8](repeating: -1, count: 256)

        private static let checkpointStride = 4096
        private static let nfcChunkTargetBytes = 16_384

        private static let dotAppBytes = Array(".app".utf8)
        private static let appsSlashBytes = Array("/applications/".utf8)
        private static let tildeAppsSlashBytes = Array("~/applications/".utf8)
        private static let usersSlashBytes = Array("/users/".utf8)

        init(text: String) {
            var contiguous = text
            contiguous.makeContiguousUTF8()
            self.text = contiguous
            let rawUTF8 = Array(contiguous.utf8)
            self.textUTF8 = rawUTF8

            let ascii = Self.isAllASCII(rawUTF8, from: 0, to: rawUTF8.count)
            self.textIsASCII = ascii

            if ascii {
                self.lowerText = ""
                self.lowerUTF8 = Self.foldASCII(rawUTF8)
                self.sameUTF8Length = true
            } else {
                var lowered = contiguous.lowercased()
                lowered.makeContiguousUTF8()
                let loweredBytes = Array(lowered.utf8)
                self.lowerText = lowered
                self.lowerUTF8 = loweredBytes
                self.sameUTF8Length = (loweredBytes.count == rawUTF8.count)
            }

            let dotApp = Self.containsAllBytes(Self.dotAppBytes, in: self.lowerUTF8, cache: &self.presentLowerCache)
                && Self.findBytes(Self.dotAppBytes, in: self.lowerUTF8) != nil
            self.hasDotApp = dotApp
            if dotApp {
                self.hasApplicationsSlash = Self.containsAllBytes(Self.appsSlashBytes, in: self.lowerUTF8, cache: &self.presentLowerCache)
                    && Self.findBytes(Self.appsSlashBytes, in: self.lowerUTF8) != nil
                self.hasTildeApplicationsSlash = Self.containsAllBytes(Self.tildeAppsSlashBytes, in: self.lowerUTF8, cache: &self.presentLowerCache)
                    && Self.findBytes(Self.tildeAppsSlashBytes, in: self.lowerUTF8) != nil
            } else {
                self.hasApplicationsSlash = false
                self.hasTildeApplicationsSlash = false
            }
            self.hasUsersSlash = Self.containsAllBytes(Self.usersSlashBytes, in: self.lowerUTF8, cache: &self.presentLowerCache)
                && Self.findBytes(Self.usersSlashBytes, in: self.lowerUTF8) != nil
        }

        private static func isAllASCII(_ bytes: [UInt8], from start: Int, to end: Int) -> Bool {
            let n = end - start
            guard n > 0 else { return true }
            return bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress?.advanced(by: start) else { return true }
                var offset = 0
                while offset + 8 <= n {
                    let word = UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: UInt64.self)
                    if (word & 0x8080_8080_8080_8080) != 0 {
                        return false
                    }
                    offset += 8
                }
                while offset < n {
                    if base[offset] >= 0x80 {
                        return false
                    }
                    offset += 1
                }
                return true
            }
        }

        private static func foldASCII(_ bytes: [UInt8]) -> [UInt8] {
            let n = bytes.count
            var folded = [UInt8](repeating: 0, count: n)
            bytes.withUnsafeBufferPointer { srcBuf in
                folded.withUnsafeMutableBufferPointer { dstBuf in
                    guard let sBase = srcBuf.baseAddress, let dBase = dstBuf.baseAddress else { return }
                    var i = 0
                    while i < n {
                        let b = sBase[i]
                        dBase[i] = (b >= 0x41 && b <= 0x5A) ? (b &+ 32) : b
                        i += 1
                    }
                }
            }
            return folded
        }

        private static func containsAllBytes(
            _ needleBytes: [UInt8],
            in haystack: [UInt8],
            cache: inout [Int8]
        ) -> Bool {
            var i = needleBytes.count - 1
            while i >= 0 {
                let byte = needleBytes[i]
                let idx = Int(byte)
                let cached = cache[idx]
                let found: Bool
                if cached != -1 {
                    found = (cached == 1)
                } else {
                    found = haystack.withUnsafeBytes { buf -> Bool in
                        guard let base = buf.baseAddress, !buf.isEmpty else { return false }
                        return Darwin.memchr(base, Int32(byte), buf.count) != nil
                    }
                    cache[idx] = found ? 1 : 0
                }
                if !found {
                    return false
                }
                i -= 1
            }
            return true
        }

        private func containsAllBytes(_ needleBytes: [UInt8], inLower: Bool) -> Bool {
            if inLower {
                return Self.containsAllBytes(needleBytes, in: lowerUTF8, cache: &presentLowerCache)
            } else {
                return Self.containsAllBytes(needleBytes, in: textUTF8, cache: &presentRawCache)
            }
        }

        private static func isGraphemeAligned(
            in str: String,
            utf8: [UInt8],
            byteStart: Int,
            byteEnd: Int
        ) -> Bool {
            if byteStart > 0 {
                let prev = utf8[byteStart - 1]
                let curr = utf8[byteStart]
                if !(prev < 0x80 && curr < 0x80 && !(prev == 0x0D && curr == 0x0A)) {
                    let idx = str.utf8.index(str.startIndex, offsetBy: byteStart)
                    if idx.samePosition(in: str) == nil { return false }
                }
            }
            if byteEnd < utf8.count {
                let last = utf8[byteEnd - 1]
                let next = utf8[byteEnd]
                if !(last < 0x80 && next < 0x80 && !(last == 0x0D && next == 0x0A)) {
                    let idx = str.utf8.index(str.startIndex, offsetBy: byteEnd)
                    if idx.samePosition(in: str) == nil { return false }
                }
            }
            return true
        }

        private static func containsSpecialCaseFold(_ str: String) -> Bool {
            for scalar in str.unicodeScalars {
                switch scalar.value {
                case 0x00DF, 0x017F, 0xFB00...0xFB06:
                    return true
                default:
                    continue
                }
            }
            return false
        }

        private static func hasWordBoundaries(in str: String, range: Range<String.Index>) -> Bool {
            let beforeOK: Bool
            if range.lowerBound == str.startIndex {
                beforeOK = true
            } else {
                beforeOK = !PrivacyScanner.isIdentifierChar(str[str.index(before: range.lowerBound)])
            }
            let afterOK: Bool
            if range.upperBound == str.endIndex {
                afterOK = true
            } else {
                afterOK = !PrivacyScanner.isIdentifierChar(str[range.upperBound])
            }
            return beforeOK && afterOK
        }

        func findSubstringMatch(needle: String, caseSensitive: Bool) -> Range<String.Index>? {
            guard !needle.isEmpty else { return nil }
            let nfcNeedle = needle.precomposedStringWithCanonicalMapping

            if textIsASCII {
                if nfcNeedle.unicodeScalars.allSatisfy(\.isASCII) {
                    let key = caseSensitive ? nfcNeedle : nfcNeedle.lowercased()
                    let keyBytes = Array(key.utf8)
                    let haystack = caseSensitive ? textUTF8 : lowerUTF8
                    guard containsAllBytes(keyBytes, inLower: !caseSensitive) else { return nil }
                    var searchOffset = 0
                    while searchOffset + keyBytes.count <= haystack.count,
                          let matchStart = Self.findBytes(keyBytes, in: haystack, from: searchOffset) {
                        let matchEnd = matchStart + keyBytes.count
                        if Self.isGraphemeAligned(in: text, utf8: haystack, byteStart: matchStart, byteEnd: matchEnd) {
                            return exactRangeInText(byteStart: matchStart, byteEnd: matchEnd)
                        }
                        searchOffset = matchStart + 1
                    }
                    return nil
                } else if !caseSensitive && Self.containsSpecialCaseFold(nfcNeedle) {
                    return text.range(of: needle, options: [.caseInsensitive])
                } else {
                    return nil
                }
            }

            // Pass 1: Direct UTF-8 search on original / lowercased text
            if caseSensitive {
                let needleBytes = Array(needle.utf8)
                if containsAllBytes(needleBytes, inLower: false) {
                    var searchOffset = 0
                    while searchOffset + needleBytes.count <= textUTF8.count,
                          let matchStart = Self.findBytes(needleBytes, in: textUTF8, from: searchOffset) {
                        let matchEnd = matchStart + needleBytes.count
                        if Self.isGraphemeAligned(in: text, utf8: textUTF8, byteStart: matchStart, byteEnd: matchEnd) {
                            return exactRangeInText(byteStart: matchStart, byteEnd: matchEnd)
                        }
                        searchOffset = matchStart + 1
                    }
                }
            } else {
                let lowerNeedle = needle.lowercased()
                let needleBytes = Array(lowerNeedle.utf8)
                if containsAllBytes(needleBytes, inLower: true) {
                    var searchOffset = 0
                    while searchOffset + needleBytes.count <= lowerUTF8.count,
                          let matchStart = Self.findBytes(needleBytes, in: lowerUTF8, from: searchOffset) {
                        let matchEnd = matchStart + needleBytes.count
                        if Self.isGraphemeAligned(in: lowerText, utf8: lowerUTF8, byteStart: matchStart, byteEnd: matchEnd) {
                            switch mapLowerRangeToText(
                                lowerByteStart: matchStart,
                                lowerByteEnd: matchEnd,
                                expectedLowerNeedle: lowerNeedle,
                                originalNeedle: needle,
                                requireWordBoundaries: false
                            ) {
                            case .matched(let range):
                                return range
                            case .falseHit:
                                break
                            case .fallbackNeeded:
                                return text.range(of: needle, options: [.caseInsensitive])
                            }
                        }
                        searchOffset = matchStart + 1
                    }
                }
            }

            // Pass 2: NFC / NFD / Mixed-normalization / Special-case-fold fallback
            let needsNormalizationOrFold = !nfcNeedle.unicodeScalars.allSatisfy(\.isASCII)
                || !nfcNeedle.utf8.elementsEqual(needle.utf8)
                || (!caseSensitive && Self.containsSpecialCaseFold(nfcNeedle))
            guard needsNormalizationOrFold else { return nil }

            if !caseSensitive && Self.containsSpecialCaseFold(nfcNeedle) {
                return text.range(of: needle, options: [.caseInsensitive])
            }

            ensureNFCIndex()
            let key = caseSensitive ? nfcNeedle : nfcNeedle.lowercased()
            let keyBytes = Array(key.utf8)
            let nfcHaystack = caseSensitive ? nfcUTF8 : nfcLowerUTF8
            let nfcTargetStr = caseSensitive ? nfcText : nfcLowerText
            let hasAll = caseSensitive
                ? Self.containsAllBytes(keyBytes, in: nfcUTF8, cache: &presentNFCCache)
                : Self.containsAllBytes(keyBytes, in: nfcLowerUTF8, cache: &presentNFCLowerCache)
            guard hasAll else { return nil }

            var searchOffset = 0
            while searchOffset + keyBytes.count <= nfcHaystack.count,
                  let matchStart = Self.findBytes(keyBytes, in: nfcHaystack, from: searchOffset) {
                let matchEnd = matchStart + keyBytes.count
                if Self.isGraphemeAligned(in: nfcTargetStr, utf8: nfcHaystack, byteStart: matchStart, byteEnd: matchEnd) {
                    let slice = rawSliceRange(nfcByteStart: matchStart, nfcByteEnd: matchEnd, inLower: !caseSensitive)
                    if let r = text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive], range: slice) {
                        return r
                    }
                }
                searchOffset = matchStart + 1
            }
            return nil
        }

        func findBoundaryMatch(needle: String, caseSensitive: Bool) -> Range<String.Index>? {
            guard !needle.isEmpty else { return nil }
            let nfcNeedle = needle.precomposedStringWithCanonicalMapping

            if textIsASCII {
                if nfcNeedle.unicodeScalars.allSatisfy(\.isASCII) {
                    let searchKey = caseSensitive ? nfcNeedle : nfcNeedle.lowercased()
                    let needleBytes = Array(searchKey.utf8)
                    guard !needleBytes.isEmpty else { return nil }
                    guard containsAllBytes(needleBytes, inLower: !caseSensitive) else { return nil }
                    let haystack = caseSensitive ? textUTF8 : lowerUTF8
                    return scanBoundaryLoop(
                        needleBytes: needleBytes,
                        haystack: haystack,
                        targetStr: text,
                        onMatch: { matchStart, matchEnd in
                            .matched(exactRangeInText(byteStart: matchStart, byteEnd: matchEnd))
                        }
                    )
                } else if !caseSensitive && Self.containsSpecialCaseFold(nfcNeedle) {
                    return PrivacyScanner.findBoundaryMatchSlow(needle: needle, in: text, caseSensitive: false)
                } else {
                    return nil
                }
            }

            // Pass 1: Direct UTF-8 boundary scan
            let searchKey = caseSensitive ? needle : needle.lowercased()
            let needleBytes = Array(searchKey.utf8)
            if !needleBytes.isEmpty && containsAllBytes(needleBytes, inLower: !caseSensitive) {
                let haystack = caseSensitive ? textUTF8 : lowerUTF8
                let targetStr = caseSensitive ? text : lowerText
                var hitFallback = false
                if let direct = scanBoundaryLoop(
                    needleBytes: needleBytes,
                    haystack: haystack,
                    targetStr: targetStr,
                    onMatch: { matchStart, matchEnd in
                        if caseSensitive {
                            return .matched(exactRangeInText(byteStart: matchStart, byteEnd: matchEnd))
                        }
                        let mapped = mapLowerRangeToText(
                            lowerByteStart: matchStart,
                            lowerByteEnd: matchEnd,
                            expectedLowerNeedle: searchKey,
                            originalNeedle: needle,
                            requireWordBoundaries: true
                        )
                        if case .fallbackNeeded = mapped {
                            hitFallback = true
                        }
                        return mapped
                    }
                ) {
                    return direct
                }
                if hitFallback {
                    return PrivacyScanner.findBoundaryMatchSlow(needle: needle, in: text, caseSensitive: false)
                }
            }

            // Pass 2: NFC / NFD / Mixed-normalization / Special-case-fold fallback
            let needsNormalizationOrFold = !nfcNeedle.unicodeScalars.allSatisfy(\.isASCII)
                || !nfcNeedle.utf8.elementsEqual(needle.utf8)
                || (!caseSensitive && Self.containsSpecialCaseFold(nfcNeedle))
            guard needsNormalizationOrFold else { return nil }

            if !caseSensitive && Self.containsSpecialCaseFold(nfcNeedle) {
                return PrivacyScanner.findBoundaryMatchSlow(needle: needle, in: text, caseSensitive: false)
            }

            ensureNFCIndex()
            let key = caseSensitive ? nfcNeedle : nfcNeedle.lowercased()
            let keyBytes = Array(key.utf8)
            guard !keyBytes.isEmpty else { return nil }
            let nfcHaystack = caseSensitive ? nfcUTF8 : nfcLowerUTF8
            let nfcTargetStr = caseSensitive ? nfcText : nfcLowerText
            let hasAll = caseSensitive
                ? Self.containsAllBytes(keyBytes, in: nfcUTF8, cache: &presentNFCCache)
                : Self.containsAllBytes(keyBytes, in: nfcLowerUTF8, cache: &presentNFCLowerCache)
            guard hasAll else { return nil }

            return scanBoundaryLoop(
                needleBytes: keyBytes,
                haystack: nfcHaystack,
                targetStr: nfcTargetStr,
                onMatch: { matchStart, matchEnd in
                    let slice = rawSliceRange(nfcByteStart: matchStart, nfcByteEnd: matchEnd, inLower: !caseSensitive)
                    if let r = PrivacyScanner.findBoundaryMatchSlow(
                        needle: needle,
                        in: text,
                        caseSensitive: caseSensitive,
                        searchRange: slice
                    ) {
                        return .matched(r)
                    }
                    return .falseHit
                }
            )
        }

        private func scanBoundaryLoop(
            needleBytes: [UInt8],
            haystack: [UInt8],
            targetStr: String,
            onMatch: (Int, Int) -> LowerMapResult
        ) -> Range<String.Index>? {
            let needleStartsASCII = needleBytes[0] < 0x80
            let needleAllASCIIIdentifier = needleBytes.allSatisfy(Self.isASCIIIdentifierByte)

            var searchOffset = 0
            while searchOffset + needleBytes.count <= haystack.count,
                  let matchStart = Self.findBytes(needleBytes, in: haystack, from: searchOffset) {
                let matchEnd = matchStart + needleBytes.count

                let isAligned = Self.isGraphemeAligned(in: targetStr, utf8: haystack, byteStart: matchStart, byteEnd: matchEnd)
                if isAligned {
                    let beforeOK: Bool
                    if matchStart == 0 {
                        beforeOK = true
                    } else {
                        let prevByte = haystack[matchStart - 1]
                        if prevByte < 0x80 && needleStartsASCII {
                            beforeOK = !Self.isASCIIIdentifierByte(prevByte)
                        } else {
                            let idx = targetStr.utf8.index(targetStr.startIndex, offsetBy: matchStart)
                            let prevChar = targetStr[targetStr.index(before: idx)]
                            beforeOK = !PrivacyScanner.isIdentifierChar(prevChar)
                        }
                    }

                    let afterOK: Bool
                    if matchEnd == haystack.count {
                        afterOK = true
                    } else {
                        let nextByte = haystack[matchEnd]
                        if nextByte < 0x80 && (matchEnd + 1 == haystack.count || haystack[matchEnd + 1] < 0x80) {
                            afterOK = !Self.isASCIIIdentifierByte(nextByte)
                        } else {
                            let idx = targetStr.utf8.index(targetStr.startIndex, offsetBy: matchEnd)
                            let nextChar = targetStr[idx]
                            afterOK = !PrivacyScanner.isIdentifierChar(nextChar)
                        }
                    }

                    if beforeOK && afterOK {
                        switch onMatch(matchStart, matchEnd) {
                        case .matched(let range):
                            return range
                        case .falseHit:
                            searchOffset = matchStart + 1
                            continue
                        case .fallbackNeeded:
                            return nil
                        }
                    }
                }

                if isAligned && needleAllASCIIIdentifier {
                    var next = matchEnd
                    while next < haystack.count
                        && haystack[next] < 0x80
                        && Self.isASCIIIdentifierByte(haystack[next])
                        && (next + 1 == haystack.count || haystack[next + 1] < 0x80) {
                        next += 1
                    }
                    searchOffset = max(matchStart + 1, next)
                } else {
                    searchOffset = matchStart + 1
                }
            }

            return nil
        }

        private func exactRangeInText(byteStart: Int, byteEnd: Int) -> Range<String.Index> {
            let low = text.utf8.index(text.startIndex, offsetBy: byteStart)
            let high = text.utf8.index(low, offsetBy: byteEnd - byteStart)
            return low..<high
        }

        private func mapLowerRangeToText(
            lowerByteStart: Int,
            lowerByteEnd: Int,
            expectedLowerNeedle: String,
            originalNeedle: String,
            requireWordBoundaries: Bool
        ) -> LowerMapResult {
            if textIsASCII {
                let candidate = exactRangeInText(byteStart: lowerByteStart, byteEnd: lowerByteEnd)
                if !requireWordBoundaries || Self.hasWordBoundaries(in: text, range: candidate) {
                    return .matched(candidate)
                }
                return .falseHit
            }

            if sameUTF8Length,
               lowerByteEnd <= textUTF8.count,
               Self.isGraphemeAligned(in: text, utf8: textUTF8, byteStart: lowerByteStart, byteEnd: lowerByteEnd),
               String(decoding: textUTF8[lowerByteStart..<lowerByteEnd], as: UTF8.self).lowercased() == expectedLowerNeedle {
                let candidate = exactRangeInText(byteStart: lowerByteStart, byteEnd: lowerByteEnd)
                if !requireWordBoundaries || Self.hasWordBoundaries(in: text, range: candidate) {
                    return .matched(candidate)
                }
                // Do not return .falseHit yet: an offsetting İ...ẞ shift may mean the real match is elsewhere.
            }

            guard let (rawStart, rawEnd) = rawByteSpan(forLowerStart: lowerByteStart, lowerEnd: lowerByteEnd) else {
                return lowerCheckpointsValid ? .falseHit : .fallbackNeeded
            }

            if Self.isGraphemeAligned(in: text, utf8: textUTF8, byteStart: rawStart, byteEnd: rawEnd) {
                let candidate = exactRangeInText(byteStart: rawStart, byteEnd: rawEnd)
                if String(text[candidate]).lowercased() == expectedLowerNeedle {
                    if !requireWordBoundaries || Self.hasWordBoundaries(in: text, range: candidate) {
                        return .matched(candidate)
                    }
                    return .falseHit
                }
            }

            // Bounded ±8 Character local verification (handles partial scalar expansion like "i" inside "İ")
            let approxStart = text.utf8.index(text.startIndex, offsetBy: rawStart)
            let approxEnd = text.utf8.index(text.startIndex, offsetBy: rawEnd)
            let winStart = text.index(approxStart, offsetBy: -8, limitedBy: text.startIndex) ?? text.startIndex
            let winEnd = text.index(approxEnd, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
            if requireWordBoundaries {
                if let r = PrivacyScanner.findBoundaryMatchSlow(
                    needle: originalNeedle,
                    in: text,
                    caseSensitive: false,
                    searchRange: winStart..<winEnd
                ) {
                    return .matched(r)
                }
            } else if let r = text.range(of: originalNeedle, options: [.caseInsensitive], range: winStart..<winEnd) {
                return .matched(r)
            }
            return .falseHit
        }

        private static func lowercaseUTF8Count(rBase: UnsafePointer<UInt8>, at r: Int, seqLen: Int) -> Int {
            let b0 = rBase[r]
            let scalarVal: UInt32
            if seqLen == 2 {
                scalarVal = (UInt32(b0 & 0x1F) << 6) | UInt32(rBase[r + 1] & 0x3F)
            } else if seqLen == 3 {
                scalarVal = (UInt32(b0 & 0x0F) << 12) | (UInt32(rBase[r + 1] & 0x3F) << 6) | UInt32(rBase[r + 2] & 0x3F)
            } else {
                scalarVal = (UInt32(b0 & 0x07) << 18)
                    | (UInt32(rBase[r + 1] & 0x3F) << 12)
                    | (UInt32(rBase[r + 2] & 0x3F) << 6)
                    | UInt32(rBase[r + 3] & 0x3F)
            }
            guard let scalar = Unicode.Scalar(scalarVal) else {
                return seqLen
            }
            return scalar.properties.lowercaseMapping.utf8.count
        }

        private func ensureLowerCheckpoints() {
            guard !lowerCheckpointsBuilt else { return }
            lowerCheckpointsBuilt = true
            lowerCheckpoints.removeAll()

            let rCount = textUTF8.count
            let lCount = lowerUTF8.count
            lowerCheckpoints.reserveCapacity(rCount / Self.checkpointStride + 2)
            lowerCheckpoints.append((raw: 0, lower: 0))

            if rCount == 0 {
                lowerCheckpointsValid = (lCount == 0)
                return
            }

            var r = 0
            var l = 0
            var nextCheckpoint = Self.checkpointStride
            var valid = true

            textUTF8.withUnsafeBufferPointer { rBuf in
                lowerUTF8.withUnsafeBufferPointer { lBuf in
                    guard let rBase = rBuf.baseAddress, let lBase = lBuf.baseAddress else {
                        valid = false
                        return
                    }
                    while r < rCount && l < lCount {
                        if r >= nextCheckpoint {
                            lowerCheckpoints.append((raw: r, lower: l))
                            nextCheckpoint = r + Self.checkpointStride
                        }
                        while r + 8 <= rCount && l + 8 <= lCount && r < nextCheckpoint {
                            let w = UnsafeRawPointer(rBase.advanced(by: r)).loadUnaligned(as: UInt64.self)
                            if (w & 0x8080_8080_8080_8080) != 0 { break }
                            r += 8
                            l += 8
                        }
                        if r >= rCount || l >= lCount { break }
                        if r >= nextCheckpoint {
                            lowerCheckpoints.append((raw: r, lower: l))
                            nextCheckpoint = r + Self.checkpointStride
                        }

                        let b0 = rBase[r]
                        if b0 < 0x80 {
                            r += 1
                            l += 1
                            continue
                        }

                        let seqLen: Int
                        if b0 >= 0xC2 && b0 <= 0xDF {
                            seqLen = 2
                        } else if b0 >= 0xE0 && b0 <= 0xEF {
                            seqLen = 3
                        } else if b0 >= 0xF0 && b0 <= 0xF4 {
                            seqLen = 4
                        } else {
                            valid = false
                            return
                        }
                        guard r + seqLen <= rCount else {
                            valid = false
                            return
                        }

                        if l + seqLen <= lCount {
                            var same = true
                            for k in 0..<seqLen {
                                if rBase[r + k] != lBase[l + k] {
                                    same = false
                                    break
                                }
                            }
                            if same {
                                r += seqLen
                                l += seqLen
                                continue
                            }
                        }

                        let scalarVal: UInt32
                        if seqLen == 2 {
                            let b1 = rBase[r + 1]
                            guard (b1 & 0xC0) == 0x80 else { valid = false; return }
                            scalarVal = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
                        } else if seqLen == 3 {
                            let b1 = rBase[r + 1], b2 = rBase[r + 2]
                            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80 else { valid = false; return }
                            scalarVal = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
                        } else {
                            let b1 = rBase[r + 1], b2 = rBase[r + 2], b3 = rBase[r + 3]
                            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80 else { valid = false; return }
                            scalarVal = (UInt32(b0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) | (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)
                        }
                        guard let scalar = Unicode.Scalar(scalarVal) else {
                            valid = false
                            return
                        }
                        r += seqLen
                        l += scalar.properties.lowercaseMapping.utf8.count
                    }
                }
            }
            lowerCheckpointsValid = valid && (r == rCount && l == lCount)
        }

        private func rawByteSpan(forLowerStart lowerStart: Int, lowerEnd: Int) -> (rawStart: Int, rawEnd: Int)? {
            ensureLowerCheckpoints()
            guard lowerCheckpointsValid,
                  !lowerCheckpoints.isEmpty,
                  lowerStart >= 0,
                  lowerEnd >= lowerStart,
                  lowerEnd <= lowerUTF8.count else {
                return nil
            }

            var lo = 0
            var hi = lowerCheckpoints.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) >> 1
                if lowerCheckpoints[mid].lower <= lowerStart {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }

            var r = lowerCheckpoints[lo].raw
            var l = lowerCheckpoints[lo].lower
            var rawStart: Int? = (l == lowerStart) ? r : nil
            var rawEnd: Int? = (l == lowerEnd) ? r : nil
            let rCount = textUTF8.count
            let lCount = lowerUTF8.count

            textUTF8.withUnsafeBufferPointer { rBuf in
                lowerUTF8.withUnsafeBufferPointer { lBuf in
                    guard let rBase = rBuf.baseAddress, let lBase = lBuf.baseAddress else { return }
                    while r < rCount && l < lCount && (rawStart == nil || rawEnd == nil) {
                        if rawStart == nil {
                            while r + 8 <= rCount && l + 8 <= lowerStart {
                                let w = UnsafeRawPointer(rBase.advanced(by: r)).loadUnaligned(as: UInt64.self)
                                if (w & 0x8080_8080_8080_8080) != 0 { break }
                                r += 8
                                l += 8
                            }
                            if l == lowerStart {
                                rawStart = r
                            }
                        }
                        if rawStart != nil && rawEnd == nil {
                            while r + 8 <= rCount && l + 8 <= lowerEnd {
                                let w = UnsafeRawPointer(rBase.advanced(by: r)).loadUnaligned(as: UInt64.self)
                                if (w & 0x8080_8080_8080_8080) != 0 { break }
                                r += 8
                                l += 8
                            }
                            if l == lowerEnd {
                                rawEnd = r
                                break
                            }
                        }
                        if r >= rCount || l >= lCount { break }

                        let seqLen: Int
                        let lowerLen: Int
                        let b0 = rBase[r]
                        if b0 < 0x80 {
                            seqLen = 1
                            lowerLen = 1
                        } else {
                            if b0 >= 0xC2 && b0 <= 0xDF {
                                seqLen = 2
                            } else if b0 >= 0xE0 && b0 <= 0xEF {
                                seqLen = 3
                            } else {
                                seqLen = 4
                            }
                            if r + seqLen <= rCount && l + seqLen <= lCount {
                                var same = true
                                for k in 0..<seqLen {
                                    if rBase[r + k] != lBase[l + k] {
                                        same = false
                                        break
                                    }
                                }
                                lowerLen = same ? seqLen : Self.lowercaseUTF8Count(rBase: rBase, at: r, seqLen: seqLen)
                            } else {
                                lowerLen = Self.lowercaseUTF8Count(rBase: rBase, at: r, seqLen: seqLen)
                            }
                        }

                        let nextR = r + seqLen
                        let nextL = l + lowerLen
                        if rawStart == nil && nextL > lowerStart {
                            rawStart = r
                        }
                        if rawEnd == nil && nextL >= lowerEnd {
                            rawEnd = nextR
                        }
                        r = nextR
                        l = nextL
                    }
                }
            }

            guard let s = rawStart, let e = rawEnd, s <= e, e <= rCount else { return nil }
            return (s, e)
        }

        private func ensureNFCIndex() {
            guard !nfcIndexBuilt else { return }
            nfcIndexBuilt = true

            let rCount = textUTF8.count
            guard rCount > 0 else { return }

            nfcUTF8.reserveCapacity(rCount)
            nfcLowerUTF8.reserveCapacity(rCount)
            nfcChunks.reserveCapacity(rCount / Self.nfcChunkTargetBytes + 1)

            var pos = 0
            var rawIdx = text.startIndex
            while pos < rCount {
                let targetEnd = min(rCount, pos + Self.nfcChunkTargetBytes)
                let endPos: Int
                let endIdx: String.Index
                if targetEnd == rCount {
                    endPos = rCount
                    endIdx = text.endIndex
                } else {
                    let prevB = textUTF8[targetEnd - 1]
                    let currB = textUTF8[targetEnd]
                    if prevB < 0x80 && currB < 0x80 && !(prevB == 0x0D && currB == 0x0A) {
                        endPos = targetEnd
                        endIdx = text.utf8.index(rawIdx, offsetBy: endPos - pos)
                    } else {
                        let candidateIdx = text.utf8.index(rawIdx, offsetBy: targetEnd - pos)
                        endIdx = candidateIdx.samePosition(in: text) ?? text.index(after: candidateIdx)
                        endPos = text.utf8.distance(from: text.startIndex, to: endIdx)
                    }
                }

                nfcChunks.append(NFCChunk(
                    rawStart: rawIdx,
                    rawEnd: endIdx,
                    nfcByteStart: nfcUTF8.count,
                    nfcLowerByteStart: nfcLowerUTF8.count
                ))

                if Self.isAllASCII(textUTF8, from: pos, to: endPos) {
                    let sliceLen = endPos - pos
                    textUTF8.withUnsafeBufferPointer { buf in
                        if let base = buf.baseAddress {
                            let slicePtr = UnsafeBufferPointer(start: base.advanced(by: pos), count: sliceLen)
                            nfcUTF8.append(contentsOf: slicePtr)
                            let oldLowerCount = nfcLowerUTF8.count
                            nfcLowerUTF8.append(contentsOf: slicePtr)
                            nfcLowerUTF8.withUnsafeMutableBufferPointer { dstBuf in
                                if let dBase = dstBuf.baseAddress {
                                    var k = 0
                                    while k < sliceLen {
                                        let b = dBase[oldLowerCount + k]
                                        if b >= 0x41 && b <= 0x5A {
                                            dBase[oldLowerCount + k] = b &+ 32
                                        }
                                        k += 1
                                    }
                                }
                            }
                        }
                    }
                } else {
                    let sliceStr = String(text[rawIdx..<endIdx])
                    let nfcSlice = sliceStr.precomposedStringWithCanonicalMapping
                    let nfcLowerSlice = nfcSlice.lowercased()
                    nfcUTF8.append(contentsOf: nfcSlice.utf8)
                    nfcLowerUTF8.append(contentsOf: nfcLowerSlice.utf8)
                }

                pos = endPos
                rawIdx = endIdx
            }

            var builtNFC = String(decoding: nfcUTF8, as: UTF8.self)
            builtNFC.makeContiguousUTF8()
            nfcText = builtNFC

            var builtNFCLower = String(decoding: nfcLowerUTF8, as: UTF8.self)
            builtNFCLower.makeContiguousUTF8()
            nfcLowerText = builtNFCLower
        }

        private func chunkIndex(forByte offset: Int, inLower: Bool) -> Int {
            var lo = 0
            var hi = nfcChunks.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) >> 1
                let chunkStart = inLower ? nfcChunks[mid].nfcLowerByteStart : nfcChunks[mid].nfcByteStart
                if chunkStart <= offset {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return lo
        }

        private func rawSliceRange(nfcByteStart: Int, nfcByteEnd: Int, inLower: Bool) -> Range<String.Index> {
            guard !nfcChunks.isEmpty else { return text.startIndex..<text.endIndex }
            let first = chunkIndex(forByte: nfcByteStart, inLower: inLower)
            let last = chunkIndex(forByte: max(nfcByteStart, nfcByteEnd - 1), inLower: inLower)
            return nfcChunks[first].rawStart..<nfcChunks[last].rawEnd
        }

        private static func findBytes(
            _ needle: [UInt8],
            in haystack: [UInt8],
            from startOffset: Int = 0
        ) -> Int? {
            let nCount = needle.count
            let hCount = haystack.count
            guard nCount > 0, startOffset >= 0, startOffset + nCount <= hCount else {
                return nil
            }
            return haystack.withUnsafeBytes { hBuf in
                needle.withUnsafeBytes { nBuf in
                    guard let hBase = hBuf.baseAddress, let nBase = nBuf.baseAddress else {
                        return nil
                    }
                    let searchPtr = hBase.advanced(by: startOffset)
                    let searchLen = hCount - startOffset
                    guard let found = Darwin.memmem(searchPtr, searchLen, nBase, nCount) else {
                        return nil
                    }
                    return hBase.distance(to: UnsafeRawPointer(found))
                }
            }
        }

        private static func isASCIIIdentifierByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || b == 0x5F
        }
    }

    private static func findBoundaryMatchSlow(
        needle: String,
        in haystack: String,
        caseSensitive: Bool,
        searchRange: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var searchStart = searchRange?.lowerBound ?? haystack.startIndex
        let searchEnd = searchRange?.upperBound ?? haystack.endIndex
        while searchStart < searchEnd,
              let range = haystack.range(of: needle, options: options, range: searchStart..<searchEnd) {
            let beforeOK: Bool
            if range.lowerBound == haystack.startIndex {
                beforeOK = true
            } else {
                let prev = haystack[haystack.index(before: range.lowerBound)]
                beforeOK = !isIdentifierChar(prev)
            }

            let afterOK: Bool
            if range.upperBound == haystack.endIndex {
                afterOK = true
            } else {
                let next = haystack[range.upperBound]
                afterOK = !isIdentifierChar(next)
            }

            if beforeOK && afterOK {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isIdentifierChar(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x5F
        }
    }

    private func makeExcerpt(in text: String, around range: Range<String.Index>) -> String {
        let low = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
        let high = text.index(range.upperBound, offsetBy: 24, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[low..<high])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func extractPrintableRuns(from data: Data, minLength: Int) -> String {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return ""
            }
            let count = rawBuf.count
            var runs: [String] = []
            var current: [UInt8] = []

            func flushCurrent() {
                if current.count >= minLength {
                    runs.append(String(decoding: current, as: UTF8.self))
                }
                current.removeAll(keepingCapacity: true)
            }

            var i = 0
            while i < count {
                let b0 = base[i]
                if b0 >= 0x20 && b0 <= 0x7E {
                    current.append(b0)
                    i += 1
                    continue
                }

                if b0 >= 0xC2 && b0 <= 0xDF, i + 1 < count {
                    let b1 = base[i + 1]
                    if b1 >= 0x80 && b1 <= 0xBF {
                        let scalarVal = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
                        if scalarVal >= 0xA0 {
                            current.append(b0)
                            current.append(b1)
                            i += 2
                            continue
                        }
                    }
                } else if b0 >= 0xE0 && b0 <= 0xEF, i + 2 < count {
                    let b1 = base[i + 1]
                    let b2 = base[i + 2]
                    let validB1: Bool
                    if b0 == 0xE0 {
                        validB1 = b1 >= 0xA0 && b1 <= 0xBF
                    } else if b0 == 0xED {
                        validB1 = b1 >= 0x80 && b1 <= 0x9F
                    } else {
                        validB1 = b1 >= 0x80 && b1 <= 0xBF
                    }
                    if validB1 && b2 >= 0x80 && b2 <= 0xBF {
                        current.append(b0)
                        current.append(b1)
                        current.append(b2)
                        i += 3
                        continue
                    }
                } else if b0 >= 0xF0 && b0 <= 0xF4, i + 3 < count {
                    let b1 = base[i + 1]
                    let b2 = base[i + 2]
                    let b3 = base[i + 3]
                    let validB1: Bool
                    if b0 == 0xF0 {
                        validB1 = b1 >= 0x90 && b1 <= 0xBF
                    } else if b0 == 0xF4 {
                        validB1 = b1 >= 0x80 && b1 <= 0x8F
                    } else {
                        validB1 = b1 >= 0x80 && b1 <= 0xBF
                    }
                    if validB1 && b2 >= 0x80 && b2 <= 0xBF && b3 >= 0x80 && b3 <= 0xBF {
                        current.append(b0)
                        current.append(b1)
                        current.append(b2)
                        current.append(b3)
                        i += 4
                        continue
                    }
                }

                flushCurrent()
                i += 1
            }

            flushCurrent()
            return runs.joined(separator: "\n")
        }
    }

    private struct ICCSliceKey: Hashable {
        let start: Int
        let length: Int
    }

    private static let iccNumericTagTypes: Set<UInt32> = Set([
        "XYZ ", "para", "sf32", "uf32", "curv", "mft1", "mft2", "mAB ", "mBA ",
        "view", "meas", "sig ", "cicp", "mmod", "ncl2", "chrm", "dtim",
        "ui08", "ui16", "ui32", "ui64", "s15f", "u16f",
        "clro", "clrt", "crdi", "data", "devs", "bfd ",
        "ps2s", "ps2i", "psd0", "psd1", "psd2", "psd3",
    ].map { tag in
        let b = Array(tag.utf8)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    })

    private func extractICCUTF16BEStrings(from data: Data) -> String {
        let count = data.count
        guard count >= 4 else { return "" }

        return data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return ""
            }

            var results: [String] = []
            var seenSlices = Set<ICCSliceKey>()
            var parsedTextRanges: [Range<Int>] = []
            var numericExcluded: [Range<Int>] = []
            var decodedBytesUsed = 0
            let decodedByteBudget = max(count * 2, 4096)

            @inline(__always)
            func readU32(_ offset: Int) -> UInt32 {
                (UInt32(base[offset]) << 24)
                    | (UInt32(base[offset + 1]) << 16)
                    | (UInt32(base[offset + 2]) << 8)
                    | UInt32(base[offset + 3])
            }

            func decodeUTF16BERange(start: Int, length: Int) {
                let evenLen = length & ~1
                guard evenLen >= 2, start >= 0, start + evenLen <= count else { return }
                let key = ICCSliceKey(start: start, length: evenLen)
                guard seenSlices.insert(key).inserted else { return }
                guard decodedBytesUsed + evenLen <= decodedByteBudget else { return }
                decodedBytesUsed += evenLen
                parsedTextRanges.append(start..<(start + evenLen))
                let sliceData = Data(bytes: base.advanced(by: start), count: evenLen)
                if let str = String(data: sliceData, encoding: .utf16BigEndian) {
                    let normalized = str.replacingOccurrences(of: "\0", with: "\n")
                    if !normalized.isEmpty {
                        results.append(normalized)
                    }
                }
            }

            func parseMLUCTag(at tagOff: Int, tagLimit: Int) {
                guard tagOff >= 0, tagOff + 16 <= tagLimit else { return }
                guard base[tagOff] == 0x6D, base[tagOff + 1] == 0x6C,
                      base[tagOff + 2] == 0x75, base[tagOff + 3] == 0x63,
                      base[tagOff + 4] == 0x00, base[tagOff + 5] == 0x00,
                      base[tagOff + 6] == 0x00, base[tagOff + 7] == 0x00 else { return }
                let numRecords = readU32(tagOff + 8)
                let recordSize = readU32(tagOff + 12)
                guard numRecords > 0, numRecords <= 4096, recordSize >= 12, recordSize <= 4096 else { return }
                let tableBytes = UInt64(numRecords) * UInt64(recordSize)
                guard UInt64(tagOff) + 16 + tableBytes <= UInt64(tagLimit) else { return }
                numericExcluded.append(tagOff..<(tagOff + 16 + Int(tableBytes)))

                for i in 0..<Int(numRecords) {
                    let recOff = tagOff + 16 + i * Int(recordSize)
                    let strLenU32 = readU32(recOff + 4)
                    let strOffU32 = readU32(recOff + 8)
                    guard strLenU32 >= 2 else { continue }
                    guard UInt64(tagOff) + UInt64(strOffU32) + UInt64(strLenU32) <= UInt64(tagLimit) else { continue }
                    decodeUTF16BERange(start: tagOff + Int(strOffU32), length: Int(strLenU32))
                }
            }

            func parseDescTag(at tagOff: Int, tagLimit: Int) {
                guard tagOff >= 0, tagOff + 12 <= tagLimit else { return }
                guard base[tagOff] == 0x64, base[tagOff + 1] == 0x65,
                      base[tagOff + 2] == 0x73, base[tagOff + 3] == 0x63 else { return }
                let asciiCount = readU32(tagOff + 8)
                guard UInt64(tagOff) + 12 + UInt64(asciiCount) + 8 <= UInt64(tagLimit) else { return }
                let uniHeaderOff = tagOff + 12 + Int(asciiCount)
                numericExcluded.append(tagOff..<(uniHeaderOff + 8))
                let unicodeCount = readU32(uniHeaderOff + 4)
                let uniByteLen = UInt64(unicodeCount) * 2
                guard unicodeCount > 0, UInt64(uniHeaderOff) + 8 + uniByteLen <= UInt64(tagLimit) else { return }
                decodeUTF16BERange(start: uniHeaderOff + 8, length: Int(uniByteLen))
            }

            func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
                guard !ranges.isEmpty else { return [] }
                let sorted = ranges.sorted {
                    if $0.lowerBound != $1.lowerBound { return $0.lowerBound < $1.lowerBound }
                    return $0.upperBound < $1.upperBound
                }
                var merged: [Range<Int>] = [sorted[0]]
                for r in sorted.dropFirst() {
                    if r.lowerBound <= merged[merged.count - 1].upperBound {
                        if r.upperBound > merged[merged.count - 1].upperBound {
                            merged[merged.count - 1] = merged[merged.count - 1].lowerBound..<r.upperBound
                        }
                    } else {
                        merged.append(r)
                    }
                }
                return merged
            }

            // (a) Structured ICC header + tag table parsing
            if count >= 132,
               base[36] == 0x61, base[37] == 0x63, base[38] == 0x73, base[39] == 0x70 { // "acsp"
                let tagCountU32 = readU32(128)
                if tagCountU32 <= 512, 132 + UInt64(tagCountU32) * 12 <= UInt64(count) {
                    let tagCount = Int(tagCountU32)
                    numericExcluded.append(0..<(132 + tagCount * 12))
                    for t in 0..<tagCount {
                        let entryOff = 132 + t * 12
                        let tagOffU32 = readU32(entryOff + 4)
                        let tagSizeU32 = readU32(entryOff + 8)
                        guard tagSizeU32 >= 4, UInt64(tagOffU32) + UInt64(tagSizeU32) <= UInt64(count) else { continue }
                        let tagOff = Int(tagOffU32)
                        let tagLimit = tagOff + Int(tagSizeU32)
                        let typeSig = readU32(tagOff)
                        if typeSig == 0x6D6C7563 { // "mluc"
                            parseMLUCTag(at: tagOff, tagLimit: tagLimit)
                        } else if typeSig == 0x64657363 { // "desc"
                            parseDescTag(at: tagOff, tagLimit: tagLimit)
                        } else if Self.iccNumericTagTypes.contains(typeSig) {
                            numericExcluded.append(tagOff..<tagLimit)
                        }
                    }
                }
            }

            // (b) Standalone "mluc\0\0\0\0" memmem scan
            let preScanExcluded = mergeRanges(numericExcluded)
            let mlucSig: [UInt8] = [0x6D, 0x6C, 0x75, 0x63, 0x00, 0x00, 0x00, 0x00]
            var sigOffset = 0
            while sigOffset + mlucSig.count <= count {
                let hitOff: Int? = mlucSig.withUnsafeBytes { sigBuf in
                    guard let sigBase = sigBuf.baseAddress else { return nil }
                    let searchPtr = UnsafeRawPointer(base.advanced(by: sigOffset))
                    guard let found = Darwin.memmem(searchPtr, count - sigOffset, sigBase, mlucSig.count) else {
                        return nil
                    }
                    return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                }
                guard let hit = hitOff else { break }
                let insideExcluded = preScanExcluded.contains { $0.contains(hit) }
                if !insideExcluded {
                    parseMLUCTag(at: hit, tagLimit: count)
                }
                sigOffset = hit + 4
            }

            // (c) Filtered even & odd UTF-16BE printable-run fallback (minCodeUnits = 4)
            let mergedNumeric = mergeRanges(numericExcluded)
            let mergedParsed = mergeRanges(parsedTextRanges)

            @inline(__always)
            func isPrintableASCIIByte(_ b: UInt8) -> Bool {
                b >= 0x20 && b <= 0x7E
            }

            @inline(__always)
            func isInPureASCII4Run(at offset: Int) -> Bool {
                guard isPrintableASCIIByte(base[offset]), isPrintableASCIIByte(base[offset + 1]) else {
                    return false
                }
                var runLen = 2
                if offset >= 1 && isPrintableASCIIByte(base[offset - 1]) {
                    runLen += 1
                    if offset >= 2 && isPrintableASCIIByte(base[offset - 2]) {
                        runLen += 1
                    }
                }
                if runLen >= 4 { return true }
                if offset + 2 < count && isPrintableASCIIByte(base[offset + 2]) {
                    runLen += 1
                    if offset + 3 < count && isPrintableASCIIByte(base[offset + 3]) {
                        runLen += 1
                    }
                }
                return runLen >= 4
            }

            for phase in 0...1 {
                var numIdx = 0
                var parsedIdx = 0
                var pos = phase
                var units: [UInt16] = []

                func flushUnits() {
                    if units.count >= 4 {
                        let s = String(decoding: units, as: UTF16.self)
                        if !s.isEmpty {
                            results.append(s)
                        }
                    }
                    units.removeAll(keepingCapacity: true)
                }

                while pos + 1 < count {
                    let u = (UInt16(base[pos]) << 8) | UInt16(base[pos + 1])
                    if u < 0x0020 || (u >= 0x007F && u < 0x00A0) {
                        if !units.isEmpty { flushUnits() }
                        pos += 2
                        continue
                    }

                    while parsedIdx < mergedParsed.count && mergedParsed[parsedIdx].upperBound <= pos {
                        parsedIdx += 1
                    }
                    if parsedIdx < mergedParsed.count && mergedParsed[parsedIdx].lowerBound < pos + 2 {
                        if !units.isEmpty { flushUnits() }
                        pos += 2
                        continue
                    }

                    if u <= 0x007E {
                        units.append(u)
                        pos += 2
                        continue
                    }

                    while numIdx < mergedNumeric.count && mergedNumeric[numIdx].upperBound <= pos {
                        numIdx += 1
                    }
                    let inNumeric = numIdx < mergedNumeric.count && mergedNumeric[numIdx].lowerBound < pos + 2
                    if inNumeric || isInPureASCII4Run(at: pos) {
                        if !units.isEmpty { flushUnits() }
                        pos += 2
                        continue
                    }

                    if u >= 0xD800 && u <= 0xDBFF {
                        if pos + 3 < count {
                            let low = (UInt16(base[pos + 2]) << 8) | UInt16(base[pos + 3])
                            if low >= 0xDC00 && low <= 0xDFFF {
                                var pIdx2 = parsedIdx
                                while pIdx2 < mergedParsed.count && mergedParsed[pIdx2].upperBound <= pos + 2 {
                                    pIdx2 += 1
                                }
                                let lowInParsed = pIdx2 < mergedParsed.count && mergedParsed[pIdx2].lowerBound < pos + 4
                                var nIdx2 = numIdx
                                while nIdx2 < mergedNumeric.count && mergedNumeric[nIdx2].upperBound <= pos + 2 {
                                    nIdx2 += 1
                                }
                                let lowInNumeric = nIdx2 < mergedNumeric.count && mergedNumeric[nIdx2].lowerBound < pos + 4
                                if !lowInParsed && !lowInNumeric && !isInPureASCII4Run(at: pos + 2) {
                                    units.append(u)
                                    units.append(low)
                                    pos += 4
                                    continue
                                }
                            }
                        }
                        if !units.isEmpty { flushUnits() }
                        pos += 2
                        continue
                    }

                    let isPrintableBMP = (u >= 0x00A0 && u <= 0xD7FF)
                        || (u >= 0xF900 && u <= 0xFFFD && !(u >= 0xFDD0 && u <= 0xFDEF))
                    if isPrintableBMP {
                        units.append(u)
                    } else if !units.isEmpty {
                        flushUnits()
                    }
                    pos += 2
                }
                flushUnits()
            }

            return results.joined(separator: "\n")
        }
    }

    private func parseSipsDimension(key: String, from output: String) -> Int? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\(key):") {
                let valStr = line.dropFirst("\(key):".count).trimmingCharacters(in: .whitespaces)
                return Int(valStr)
            }
        }
        return nil
    }

    private func computeSampledPixelStats(cgImage: CGImage, sampleSide: Int) -> (distinctColors: Int, luminanceStdDev: Double) {
        let width = sampleSide
        let height = sampleSide
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return (0, 0.0)
        }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colors = Set<UInt32>()
        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i]
            let g = pixels[i + 1]
            let b = pixels[i + 2]
            let a = pixels[i + 3]
            let packed = (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)
            colors.insert(packed)
            let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            luminances.append(luma)
        }

        let count = Double(max(1, luminances.count))
        let mean = luminances.reduce(0.0, +) / count
        let variance = luminances.reduce(0.0) { acc, v in
            let d = v - mean
            return acc + d * d
        } / count
        return (colors.count, sqrt(variance))
    }
}

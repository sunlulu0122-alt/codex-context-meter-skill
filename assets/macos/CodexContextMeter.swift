import AppKit
import ApplicationServices
import Combine
import SwiftUI
import UserNotifications

private let codexBundleIdentifier = "com.openai.codex"
private let contextMeterBundleIdentifier = "com.sunlulu.codex-context-meter"
private let maxRolloutTailBytes = 2 * 1024 * 1024
private let defaultAutomaticHandoffThreshold = 80.0
private let automaticHandoffThresholdDefaultsKey = "automaticHandoff.thresholdPercent"
private let automaticHandoffEnabledDefaultsKey = "automaticHandoff.enabled"

private enum CodexExecutableLocator {
    static func locate() -> URL? {
        var candidates: [URL] = []
        if let runningBundle = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == codexBundleIdentifier
        })?.bundleURL {
            candidates.append(
                runningBundle.appendingPathComponent("Contents/Resources/codex")
            )
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
        ])
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

private enum WhaleIconLoader {
    static let image: NSImage? = {
        let bundled = Bundle.main.url(
            forResource: "WhaleContextIcon",
            withExtension: "png"
        )
        let development = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent("desktop/WhaleContextIcon.png")
        return [bundled, development]
            .compactMap { $0 }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            .flatMap(NSImage.init(contentsOf:))
    }()
}

private struct UsageBreakdown: Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    var freshInputTokens: Int64 { max(0, inputTokens - cachedInputTokens) }
    var regularOutputTokens: Int64 { max(0, outputTokens - reasoningOutputTokens) }
}

private struct QuotaWindowSnapshot: Equatable {
    let usedPercent: Double
    let durationMinutes: Int64?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

private struct SpendQuotaSnapshot: Equatable {
    let limit: String
    let used: String
    let remainingPercent: Double
    let resetsAt: Date
}

private struct AccountQuotaSnapshot: Equatable {
    let limitName: String?
    let primary: QuotaWindowSnapshot?
    let secondary: QuotaWindowSnapshot?
    let individualLimit: SpendQuotaSnapshot?
    let creditBalance: String?
    let availableResetCredits: Int64?
    let sampledAt: Date

    var hasDisplayableValue: Bool {
        primary != nil
            || secondary != nil
            || individualLimit != nil
            || creditBalance != nil
            || availableResetCredits != nil
    }
}

private struct TaskEstimateSnapshot: Equatable {
    let startedAt: Date
    let estimatedCompletionAt: Date?
    let confidence: String?
    let sampleCount: Int

    var elapsedSeconds: TimeInterval {
        max(0, Date().timeIntervalSince(startedAt))
    }
}

private struct ContextSnapshot: Equatable {
    let threadId: String
    let threadName: String
    let modelName: String?
    let usage: UsageBreakdown
    let contextWindow: Int64
    let sampledAt: Date
    let lastCompactionAt: Date?
    let taskEstimate: TaskEstimateSnapshot?

    var usedPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return max(0, min(100, Double(usage.totalTokens) / Double(contextWindow) * 100))
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var remainingTokens: Int64 { max(0, contextWindow - usage.totalTokens) }
}

private struct ThreadIndexEntry {
    let id: String
    let name: String
    let updatedAt: Date?
}

private enum JSONValue {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private enum DateParser {
    private static let fractional = ISO8601DateFormatter()
    private static let standard = ISO8601DateFormatter()

    static func iso8601(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

private enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000 {
            return String(format: number >= 10_000_000 ? "%.1fM" : "%.2fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: number >= 100_000 ? "%.0fK" : "%.1fK", number / 1_000)
        }
        return "\(value)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func quotaPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        if minutes > 0 { return "\(minutes)分 \(remainingSeconds)秒" }
        return "\(remainingSeconds)秒"
    }
}

private enum TaskEstimator {
    static func estimate(
        startedAt: Date?,
        latestCompletedAt: Date?,
        completedDurations: [TimeInterval],
        now: Date = Date()
    ) -> TaskEstimateSnapshot? {
        guard let startedAt,
              latestCompletedAt == nil || startedAt > latestCompletedAt!
        else { return nil }

        let samples = completedDurations
            .filter { $0 >= 5 && $0 <= 4 * 60 * 60 }
            .prefix(12)
            .sorted()
        guard samples.count >= 2 else {
            return TaskEstimateSnapshot(
                startedAt: startedAt,
                estimatedCompletionAt: nil,
                confidence: nil,
                sampleCount: samples.count
            )
        }

        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let baseline = median(Array(samples))
        let longerSamples = samples.filter { $0 > elapsed }
        let estimatedTotal: TimeInterval
        if baseline > elapsed {
            estimatedTotal = baseline
        } else if !longerSamples.isEmpty {
            estimatedTotal = median(longerSamples)
        } else {
            estimatedTotal = max(elapsed * 1.25, elapsed + 60)
        }
        let cappedTotal = min(
            max(estimatedTotal, elapsed + 15),
            max(elapsed + 15, 4 * 60 * 60)
        )
        return TaskEstimateSnapshot(
            startedAt: startedAt,
            estimatedCompletionAt: startedAt.addingTimeInterval(cappedTotal),
            confidence: samples.count >= 6 ? "中" : "低",
            sampleCount: samples.count
        )
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

private enum QuotaLabel {
    static func remaining(
        for window: QuotaWindowSnapshot,
        fallback: String
    ) -> String {
        guard let minutes = window.durationMinutes else { return fallback }
        if minutes >= 6 * 24 * 60, minutes <= 8 * 24 * 60 {
            return "每周额度剩余"
        }
        if minutes == 24 * 60 {
            return "每日额度剩余"
        }
        if minutes % 60 == 0, minutes <= 48 * 60 {
            return "\(minutes / 60) 小时额度剩余"
        }
        return fallback
    }

    static func reset(
        for window: QuotaWindowSnapshot,
        fallback: String
    ) -> String {
        remaining(for: window, fallback: fallback)
            .replacingOccurrences(of: "剩余", with: "")
    }
}

private enum AccountQuotaError: LocalizedError {
    case executableUnavailable
    case launchFailed(String)
    case initializeFailed
    case responseUnavailable
    case serverError(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Codex 官方程序不可用"
        case .launchFailed(let message):
            return "无法启动 Codex 官方额度读取：\(message)"
        case .initializeFailed:
            return "Codex 官方额度服务初始化失败"
        case .responseUnavailable:
            return "Codex 官方额度服务没有返回数据"
        case .serverError(let message):
            return "Codex 官方额度服务返回错误：\(message)"
        case .malformedResponse:
            return "Codex 官方额度数据格式无法识别"
        }
    }
}

private enum AutomaticHandoffError: LocalizedError {
    case codexUnavailable
    case invalidRollout
    case appServerStopped
    case malformedResponse
    case server(String)
    case deepLinkUnavailable

    var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            return "找不到 Codex 官方本机程序"
        case .invalidRollout:
            return "无法读取当前任务的本机交接信息"
        case .appServerStopped:
            return "Codex App Server 未返回结果"
        case .malformedResponse:
            return "Codex App Server 返回格式不完整"
        case .server(let message):
            return "Codex App Server：\(message)"
        case .deepLinkUnavailable:
            return "新任务已创建，但无法打开 Codex 任务链接"
        }
    }
}

private struct AutomaticHandoffPackage {
    let sourceThreadId: String
    let sourceThreadName: String
    let nextThreadName: String
    let cwd: String
    let markdown: String
}

private enum ThreadNameSequencer {
    private static let automaticSuffix = "（自动交接）"
    private static let numberedName = try! NSRegularExpression(
        pattern: "^(.*?)(\\s+)([0-9]+)$"
    )

    /// Mirrors the user's existing task-title convention (for example,
    /// “赛博办公室开发 3” becomes “赛博办公室开发 4”). The session index is
    /// read-only and is deliberately used instead of Codex's private database.
    static func nextName(after sourceName: String) -> String {
        let source = normalized(sourceName)
        let indexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        let names = (try? String(contentsOf: indexURL, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return JSONValue.string(item["thread_name"])
            } ?? []
        return nextName(after: source, among: names)
    }

    static func nextName(after sourceName: String, among names: [String]) -> String {
        let source = normalized(sourceName)
        let range = NSRange(source.startIndex..., in: source)
        guard let match = numberedName.firstMatch(in: source, range: range),
              let baseRange = Range(match.range(at: 1), in: source),
              let separatorRange = Range(match.range(at: 2), in: source),
              let numberRange = Range(match.range(at: 3), in: source),
              let sourceNumber = Int(source[numberRange])
        else {
            return "\(source) 2"
        }
        let base = String(source[baseRange])
        let separator = String(source[separatorRange])
        let maximum = names.reduce(sourceNumber) { currentMaximum, rawName in
            let candidate = normalized(rawName)
            let candidateRange = NSRange(candidate.startIndex..., in: candidate)
            guard let candidateMatch = numberedName.firstMatch(in: candidate, range: candidateRange),
                  let candidateBaseRange = Range(candidateMatch.range(at: 1), in: candidate),
                  let candidateNumberRange = Range(candidateMatch.range(at: 3), in: candidate),
                  String(candidate[candidateBaseRange]) == base,
                  let number = Int(candidate[candidateNumberRange])
            else { return currentMaximum }
            return max(currentMaximum, number)
        }
        return "\(base)\(separator)\(maximum + 1)"
    }

    private static func normalized(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix(automaticSuffix) {
            value.removeLast(automaticSuffix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? "Codex 任务" : value
    }
}

private enum AutomaticHandoffBuilder {
    static func build(
        from rolloutURL: URL,
        snapshot: ContextSnapshot,
        threshold: Double
    ) throws -> AutomaticHandoffPackage {
        guard let content = try? String(contentsOf: rolloutURL, encoding: .utf8)
        else { throw AutomaticHandoffError.invalidRollout }

        var cwd: String?
        var recentMessages: [(role: String, text: String)] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any]
            else { continue }
            if root["type"] as? String == "session_meta", cwd == nil {
                cwd = JSONValue.string(payload["cwd"])
            }
            guard root["type"] as? String == "response_item",
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant",
                  let items = payload["content"] as? [[String: Any]]
            else { continue }
            let text = items.compactMap { item -> String? in
                let type = item["type"] as? String
                guard type == "input_text" || type == "output_text" else { return nil }
                return item["text"] as? String
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            recentMessages.append((role, truncate(text, limit: 1_600)))
        }

        guard let cwd, !cwd.isEmpty else {
            throw AutomaticHandoffError.invalidRollout
        }
        let recent = Array(recentMessages.suffix(12))
        let latestUser = recent.last(where: { $0.role == "user" })?.text
            ?? "未能从本机记录提取，请先读取来源任务。"
        let assistantNotes = recent
            .filter { $0.role == "assistant" }
            .suffix(4)
            .map { "- \($0.text)" }
            .joined(separator: "\n")
        let recentTranscript = recent.map {
            "### \($0.role == "user" ? "用户" : "Codex")\n\($0.text)"
        }
        .joined(separator: "\n\n")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let nextThreadName = ThreadNameSequencer.nextName(after: snapshot.threadName)
        let markdown = """
        # Codex 自动交接包

        来源任务：\(snapshot.threadName)
        来源 Thread ID：\(snapshot.threadId)
        生成时间：\(timestamp)
        触发依据：上下文仪表读取到真实使用率 \(TokenFormatter.percent(snapshot.usedPercent))，达到 \(Int(threshold))% 阈值。

        ## 用户目标

        \(latestUser)

        ## 已完成

        以下是来源任务最近的 Codex 回显，属于本机记录摘录，接手后必须结合 Git 状态和文件实际内容复核：
        \(assistantNotes.isEmpty ? "- 暂无可提取的完成回显。" : assistantNotes)

        ## 进行中

        这是同一项工作的后续任务，不是一个空白的新对话。必须把本交接包视为来源任务的工作状态：先检查工作区和运行状态，随后直接继续处理来源任务最后一项用户要求，避免重复已经完成的工作或只回复“已收到”。

        ## 关键文件/路径

        - 项目目录：\(cwd)
        - 来源任务记录：\(rolloutURL.path)
        - 本交接包由 Codex 上下文仪表在本机生成。

        ## 重要决定

        - 只以上下文仪表的真实百分比触发自动交接。
        - 当前任务完成后才创建下一任务，不中断原子操作。
        - 使用 Codex 官方 App Server 创建任务，并使用已注册的 `codex://threads/<threadId>` 打开。

        ## 禁止事项

        - 不读取 `~/.codex/auth.json`。
        - 不写 Codex SQLite。
        - 不伪造状态、进度、额度或上下文百分比。
        - 保留全部未提交修改，不做破坏性 Git 操作。
        - 未经用户明确要求，不发送外部消息，不归档、中断或删除其他任务。

        ## 验证结果

        - 交接触发值：\(TokenFormatter.percent(snapshot.usedPercent))（设置阈值 \(Int(threshold))%）。
        - 上下文窗口：\(snapshot.usage.totalTokens) / \(snapshot.contextWindow) tokens。
        - 交接包内容来自本机只读 rollout；“已完成”仍需按实际文件和测试结果复核。

        ## 下一步

        1. 完整读取本交接包。
        2. 在项目目录执行 `git status`，保留所有既有修改。
        3. 复核最后一项用户要求、现有代码和验证结果。
        4. 从未完成处继续执行实际工作，修改后执行相应验证；不要等待用户重复说明任务。

        ## 最近对话摘录

        \(recentTranscript)
        """
        return AutomaticHandoffPackage(
            sourceThreadId: snapshot.threadId,
            sourceThreadName: snapshot.threadName,
            nextThreadName: nextThreadName,
            cwd: cwd,
            markdown: markdown
        )
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n…（摘录已截断）"
    }
}

private final class CodexHandoffClient {
    func createNextThread(
        package: AutomaticHandoffPackage,
        modelName: String?
    ) throws -> String {
        guard let executable = CodexExecutableLocator.locate()
        else { throw AutomaticHandoffError.codexUnavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 45,
            execute: timeout
        )
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try write(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-context-meter",
                        "version": "1.3",
                    ],
                ],
            ],
            to: input.fileHandleForWriting
        )
        _ = try response(id: 1, from: output.fileHandleForReading)
        try write(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )

        var startParams: [String: Any] = ["cwd": package.cwd]
        if let modelName, !modelName.isEmpty {
            startParams["model"] = modelName
        }
        try write(
            ["id": 2, "method": "thread/start", "params": startParams],
            to: input.fileHandleForWriting
        )
        let started = try response(id: 2, from: output.fileHandleForReading)
        guard let result = started["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let threadId = thread["id"] as? String,
              !threadId.isEmpty
        else { throw AutomaticHandoffError.malformedResponse }

        try write(
            [
                "id": 3,
                "method": "thread/name/set",
                "params": ["threadId": threadId, "name": package.nextThreadName],
            ],
            to: input.fileHandleForWriting
        )
        _ = try response(id: 3, from: output.fileHandleForReading)

        let prompt = """
        这是由 Codex 上下文仪表在来源任务达到 80% 后创建的同一工作续接任务，不是空白对话。
        不要要求用户重复说明，也不要只确认收到。请完整读取以下交接包，在其中指定的项目目录检查现状后，立刻从未完成处继续实际工作：

        \(package.markdown)
        """
        try write(
            [
                "id": 4,
                "method": "turn/start",
                "params": [
                    "threadId": threadId,
                    "input": [["type": "text", "text": prompt]],
                ],
            ],
            to: input.fileHandleForWriting
        )
        _ = try response(id: 4, from: output.fileHandleForReading)
        return threadId
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func response(id: Int64, from handle: FileHandle) throws -> [String: Any] {
        while let message = nextLine(from: handle) {
            guard JSONValue.int64(message["id"]) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw AutomaticHandoffError.server(
                    JSONValue.string(error["message"]) ?? "未知错误"
                )
            }
            return message
        }
        throw AutomaticHandoffError.appServerStopped
    }

    private func nextLine(from handle: FileHandle) -> [String: Any]? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else {
                guard !data.isEmpty else { return nil }
                break
            }
            if byte.first == 0x0A { break }
            data.append(byte)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private final class CodexAccountReader {
    func fetch() throws -> AccountQuotaSnapshot {
        guard let codexExecutableURL = CodexExecutableLocator.locate() else {
            throw AccountQuotaError.executableUnavailable
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = codexExecutableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AccountQuotaError.launchFailed(error.localizedDescription)
        }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 20,
            execute: timeout
        )
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try writeJSONLine(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-context-meter",
                        "version": "1.0",
                    ],
                ],
            ],
            to: input.fileHandleForWriting
        )

        guard let initialize = nextJSONLine(from: output.fileHandleForReading),
              JSONValue.int64(initialize["id"]) == 1,
              initialize["result"] != nil
        else {
            throw AccountQuotaError.initializeFailed
        }

        try writeJSONLine(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )
        try writeJSONLine(
            ["id": 2, "method": "account/rateLimits/read"],
            to: input.fileHandleForWriting
        )

        while let response = nextJSONLine(from: output.fileHandleForReading) {
            guard JSONValue.int64(response["id"]) == 2 else { continue }
            if let error = JSONValue.dictionary(response["error"]) {
                let message = JSONValue.string(error["message"]) ?? "未知错误"
                throw AccountQuotaError.serverError(message)
            }
            guard let result = JSONValue.dictionary(response["result"]) else {
                throw AccountQuotaError.malformedResponse
            }
            return try parse(result)
        }
        throw AccountQuotaError.responseUnavailable
    }

    private func parse(_ result: [String: Any]) throws -> AccountQuotaSnapshot {
        let legacy = JSONValue.dictionary(result["rateLimits"])
        let byLimitId = JSONValue.dictionary(result["rateLimitsByLimitId"])
        let selected = JSONValue.dictionary(byLimitId?["codex"])
            ?? byLimitId?.values.compactMap(JSONValue.dictionary).first
            ?? legacy
        guard let selected else { throw AccountQuotaError.malformedResponse }

        let credits = JSONValue.dictionary(selected["credits"])
        let resetCredits = JSONValue.dictionary(result["rateLimitResetCredits"])
        let snapshot = AccountQuotaSnapshot(
            limitName: JSONValue.string(selected["limitName"]),
            primary: parseWindow(selected["primary"]),
            secondary: parseWindow(selected["secondary"]),
            individualLimit: parseSpendLimit(selected["individualLimit"]),
            creditBalance: JSONValue.string(credits?["balance"]),
            availableResetCredits: JSONValue.int64(resetCredits?["availableCount"]),
            sampledAt: Date()
        )
        guard snapshot.hasDisplayableValue else {
            throw AccountQuotaError.malformedResponse
        }
        return snapshot
    }

    private func parseWindow(_ value: Any?) -> QuotaWindowSnapshot? {
        guard let object = JSONValue.dictionary(value),
              let usedPercent = JSONValue.double(object["usedPercent"])
        else { return nil }
        let resetsAt = JSONValue.int64(object["resetsAt"]).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return QuotaWindowSnapshot(
            usedPercent: usedPercent,
            durationMinutes: JSONValue.int64(object["windowDurationMins"]),
            resetsAt: resetsAt
        )
    }

    private func parseSpendLimit(_ value: Any?) -> SpendQuotaSnapshot? {
        guard let object = JSONValue.dictionary(value),
              let limit = JSONValue.string(object["limit"]),
              let used = JSONValue.string(object["used"]),
              let remainingPercent = JSONValue.double(object["remainingPercent"]),
              let resetsAt = JSONValue.int64(object["resetsAt"])
        else { return nil }
        return SpendQuotaSnapshot(
            limit: limit,
            used: used,
            remainingPercent: remainingPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt))
        )
    }

    private func writeJSONLine(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func nextJSONLine(from handle: FileHandle) -> [String: Any]? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else {
                guard !data.isEmpty else { return nil }
                break
            }
            if byte.first == 0x0A { break }
            data.append(byte)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private final class RolloutReader {
    private struct TaskHistory {
        var offset: UInt64 = 0
        var remainder = Data()
        var latestStartedAt: Date?
        var latestCompletedAt: Date?
        var completedDurations: [TimeInterval] = []
    }

    private var taskHistoryByPath: [String: TaskHistory] = [:]

    func snapshot(
        from url: URL,
        threadId: String,
        threadName: String
    ) -> ContextSnapshot? {
        guard let data = readTail(url: url) else { return nil }
        guard let parsed = parse(data: data, threadId: threadId, threadName: threadName)
        else { return nil }
        let history = updateTaskHistory(url: url)
        return ContextSnapshot(
            threadId: parsed.threadId,
            threadName: parsed.threadName,
            modelName: parsed.modelName,
            usage: parsed.usage,
            contextWindow: parsed.contextWindow,
            sampledAt: parsed.sampledAt,
            lastCompactionAt: parsed.lastCompactionAt,
            taskEstimate: TaskEstimator.estimate(
                startedAt: history.latestStartedAt,
                latestCompletedAt: history.latestCompletedAt,
                completedDurations: history.completedDurations
            ) ?? parsed.taskEstimate
        )
    }

    func parse(
        data: Data,
        threadId: String,
        threadName: String
    ) -> ContextSnapshot? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        var latestUsage: (UsageBreakdown, Int64, Date)?
        var latestCompaction: Date?
        var latestModelName: String?
        var latestTaskStartedAt: Date?
        var latestTaskCompletedAt: Date?
        var completedTaskDurations: [TimeInterval] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rootType = root["type"] as? String,
                  let payload = root["payload"] as? [String: Any]
            else { continue }

            let timestamp = DateParser.iso8601(root["timestamp"])
            if rootType == "turn_context", latestModelName == nil {
                latestModelName = JSONValue.string(payload["model"])
                continue
            }
            guard rootType == "event_msg",
                  let payloadType = payload["type"] as? String
            else { continue }
            if payloadType == "task_started", latestTaskStartedAt == nil {
                latestTaskStartedAt = timestamp
            }
            if payloadType == "task_complete" {
                if latestTaskCompletedAt == nil {
                    latestTaskCompletedAt = timestamp
                }
                if completedTaskDurations.count < 12,
                   let durationMilliseconds = JSONValue.int64(payload["duration_ms"]),
                   durationMilliseconds > 0 {
                    completedTaskDurations.append(
                        TimeInterval(durationMilliseconds) / 1_000
                    )
                }
            }
            if payloadType == "context_compacted", latestCompaction == nil {
                latestCompaction = timestamp
            }
            if payloadType == "token_count", latestUsage == nil,
               let info = payload["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any],
               let totalTokens = JSONValue.int64(last["total_tokens"]),
               let contextWindow = JSONValue.int64(info["model_context_window"]),
               contextWindow > 0 {
                let usage = UsageBreakdown(
                    inputTokens: JSONValue.int64(last["input_tokens"]) ?? 0,
                    cachedInputTokens: JSONValue.int64(last["cached_input_tokens"]) ?? 0,
                    outputTokens: JSONValue.int64(last["output_tokens"]) ?? 0,
                    reasoningOutputTokens: JSONValue.int64(last["reasoning_output_tokens"]) ?? 0,
                    totalTokens: totalTokens
                )
                latestUsage = (
                    usage,
                    contextWindow,
                    timestamp ?? Date()
                )
            }
        }

        guard let latestUsage else { return nil }
        return ContextSnapshot(
            threadId: threadId,
            threadName: threadName,
            modelName: latestModelName,
            usage: latestUsage.0,
            contextWindow: latestUsage.1,
            sampledAt: latestUsage.2,
            lastCompactionAt: latestCompaction,
            taskEstimate: TaskEstimator.estimate(
                startedAt: latestTaskStartedAt,
                latestCompletedAt: latestTaskCompletedAt,
                completedDurations: completedTaskDurations
            )
        )
    }

    private func readTail(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxRolloutTailBytes)
            ? size - UInt64(maxRolloutTailBytes)
            : 0
        try? handle.seek(toOffset: start)
        let body: Data?
        do {
            body = try handle.readToEnd()
        } catch {
            return nil
        }
        guard var data = body else { return nil }
        if start > 0,
           let newline = data.firstRange(of: Data([0x0A])) {
            data.removeSubrange(data.startIndex..<newline.upperBound)
        }
        return data
    }

    private func updateTaskHistory(url: URL) -> TaskHistory {
        let key = url.path
        var history = taskHistoryByPath[key] ?? TaskHistory()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return history }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return history }
        if size < history.offset {
            history = TaskHistory()
        }
        try? handle.seek(toOffset: history.offset)
        var buffer = history.remainder
        while let chunk = try? handle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = buffer[start..<newline]
                parseTaskEvent(Data(line), into: &history)
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        history.offset = size
        history.remainder = buffer
        taskHistoryByPath[key] = history
        return history
    }

    private func parseTaskEvent(_ line: Data, into history: inout TaskHistory) {
        guard line.range(of: Data("\"task_".utf8)) != nil,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String
        else { return }
        let timestamp = DateParser.iso8601(root["timestamp"])
        if type == "task_started" {
            history.latestStartedAt = timestamp
        } else if type == "task_complete" {
            history.latestCompletedAt = timestamp
            if let duration = JSONValue.int64(payload["duration_ms"]), duration > 0 {
                history.completedDurations.append(TimeInterval(duration) / 1_000)
                if history.completedDurations.count > 12 {
                    history.completedDurations.removeFirst(
                        history.completedDurations.count - 12
                    )
                }
            }
        }
    }
}

private final class ThreadStore {
    private let codexHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    private var entriesById: [String: ThreadIndexEntry] = [:]
    private var rolloutById: [String: URL] = [:]
    private var lastRefresh = Date.distantPast
    private var lastRolloutRefresh = Date.distantPast

    var allEntries: [ThreadIndexEntry] {
        refreshIfNeeded()
        return Array(entriesById.values)
    }

    func entry(id: String) -> ThreadIndexEntry? {
        refreshIfNeeded()
        return entriesById[id]
    }

    func rolloutURL(threadId: String) -> URL? {
        refreshIfNeeded()
        refreshRolloutIndexIfNeeded()
        return rolloutById[threadId]
    }

    func mostRecentlyWrittenThread(maxAge: TimeInterval) -> ThreadIndexEntry? {
        refreshIfNeeded()
        let now = Date()
        return entriesById.values.compactMap { entry -> (ThreadIndexEntry, Date)? in
            guard let url = rolloutURL(threadId: entry.id),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= maxAge
            else { return nil }
            return (entry, modified)
        }
        .max(by: { $0.1 < $1.1 })?
        .0
    }

    private func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) >= 8 else { return }
        lastRefresh = Date()
        let indexURL = codexHome.appendingPathComponent("session_index.jsonl")
        guard let raw = try? String(contentsOf: indexURL, encoding: .utf8) else { return }
        var updated: [String: ThreadIndexEntry] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let candidate = ThreadIndexEntry(
                id: id,
                name: name,
                updatedAt: DateParser.iso8601(object["updated_at"])
            )
            if let current = updated[id],
               let currentDate = current.updatedAt,
               let candidateDate = candidate.updatedAt,
               currentDate > candidateDate {
                continue
            }
            updated[id] = candidate
        }
        entriesById = updated
        refreshRolloutIndexIfNeeded()
    }

    private func refreshRolloutIndexIfNeeded() {
        guard Date().timeIntervalSince(lastRolloutRefresh) >= 30 else { return }
        lastRolloutRefresh = Date()
        var updated = rolloutById
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator
            where url.pathExtension == "jsonl" {
                let stem = url.deletingPathExtension().lastPathComponent
                guard let idRange = stem.range(
                    of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                    options: .regularExpression
                ) else { continue }
                let id = String(stem[idRange])
                if entriesById[id] != nil { updated[id] = url }
            }
        }
        rolloutById = updated
    }
}

private struct AXNode {
    let element: AXUIElement
    let role: String
    let text: String?
    let selected: Bool
    let frame: CGRect?
}

private enum AccessibilityReader {
    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func element<T>(_ element: AXUIElement, attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func enableWebAccessibility(_ application: AXUIElement) {
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(
                application,
                attribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = self.element(element, attribute: kAXPositionAttribute),
              let sizeValue: AXValue = self.element(element, attribute: kAXSizeAttribute),
              AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func bool(_ element: AXUIElement, attribute: String) -> Bool {
        (self.element(element, attribute: attribute) as NSNumber?)?.boolValue ?? false
    }

    static func string(_ element: AXUIElement, attribute: String) -> String? {
        self.element(element, attribute: attribute)
    }

    static func nodes(root: AXUIElement, limit: Int = 5000) -> [AXNode] {
        var result: [AXNode] = []
        var queue = [root]
        var cursor = 0
        while cursor < queue.count, result.count < limit {
            let current = queue[cursor]
            cursor += 1
            let role = string(current, attribute: kAXRoleAttribute) ?? ""
            let text = [
                string(current, attribute: kAXTitleAttribute),
                string(current, attribute: kAXDescriptionAttribute),
                string(current, attribute: kAXValueAttribute),
                string(current, attribute: kAXHelpAttribute),
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            result.append(AXNode(
                element: current,
                role: role,
                text: text,
                selected: bool(current, attribute: kAXSelectedAttribute),
                frame: frame(current)
            ))
            let children: [AXUIElement] = element(current, attribute: kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children)
        }
        return result
    }
}

private struct CodexSurface {
    let composerFrame: CGRect
    let windowFrame: CGRect
    let thread: ThreadIndexEntry
    let modelMenuOpen: Bool
}

private final class CodexSurfaceReader {
    private let store: ThreadStore

    init(store: ThreadStore) {
        self.store = store
    }

    func currentSurface() -> CodexSurface? {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == codexBundleIdentifier && !$0.isTerminated
        }) else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AccessibilityReader.enableWebAccessibility(appElement)
        guard let window: AXUIElement = AccessibilityReader.element(
            appElement,
            attribute: kAXFocusedWindowAttribute
        ) else { return nil }
        guard let windowFrame = AccessibilityReader.frame(window) else { return nil }
        let nodes = AccessibilityReader.nodes(root: window)
        let composer = composerNode(nodes: nodes)
            ?? inferredComposerFrame(windowFrame: windowFrame)
        guard let thread = selectedThread(nodes: nodes, window: window)
            ?? store.mostRecentlyWrittenThread(maxAge: 60 * 60)
        else { return nil }
        return CodexSurface(
            composerFrame: composer,
            windowFrame: windowFrame,
            thread: thread,
            modelMenuOpen: isModelMenuOpen(nodes: nodes)
        )
    }

    /// Window dragging only changes the focused-window frame. Reusing the
    /// last verified composer offset avoids a full AX tree walk while dragging.
    func translatedComposerFrame(from surface: CodexSurface) -> CGRect? {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == codexBundleIdentifier && !$0.isTerminated
        }) else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window: AXUIElement = AccessibilityReader.element(
            appElement,
            attribute: kAXFocusedWindowAttribute
        ), let frame = AccessibilityReader.frame(window) else { return nil }
        return surface.composerFrame.offsetBy(
            dx: frame.minX - surface.windowFrame.minX,
            dy: frame.minY - surface.windowFrame.minY
        )
    }

    func diagnosticReport() -> [String: Any] {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == codexBundleIdentifier && !$0.isTerminated
        }) else {
            return ["codexRunning": false]
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AccessibilityReader.enableWebAccessibility(appElement)
        let focusedWindow: AXUIElement? = AccessibilityReader.element(
            appElement,
            attribute: kAXFocusedWindowAttribute
        )
        let windows: [AXUIElement] = AccessibilityReader.element(
            appElement,
            attribute: kAXWindowsAttribute
        ) ?? []
        guard let window = focusedWindow ?? windows.first else {
            return [
                "codexRunning": true,
                "accessibilityTrusted": AccessibilityReader.trusted(prompt: false),
                "windowCount": windows.count,
                "focusedWindowFound": false,
            ]
        }
        let nodes = AccessibilityReader.nodes(root: window)
        var roleCounts: [String: Int] = [:]
        for node in nodes { roleCounts[node.role, default: 0] += 1 }
        let editableFrames = nodes.compactMap { node -> [String: Any]? in
            guard ["AXTextArea", "AXTextField", "AXWebArea"].contains(node.role),
                  let frame = node.frame
            else { return nil }
            return [
                "role": node.role,
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
            ]
        }
        let knownNames = Set(store.allEntries.map(\.name))
        let threadMatches = nodes.compactMap { node -> [String: Any]? in
            guard let text = node.text,
                  knownNames.contains(text)
            else { return nil }
            var item: [String: Any] = [
                "name": text,
                "role": node.role,
                "selected": node.selected,
            ]
            if let frame = node.frame {
                item["x"] = frame.minX
                item["y"] = frame.minY
                item["width"] = frame.width
                item["height"] = frame.height
            }
            return item
        }
        let resolvedSurface = currentSurface()
        let resolved = resolvedSurface.map {
            [
                "threadId": $0.thread.id,
                "threadName": $0.thread.name,
                "composerX": $0.composerFrame.minX,
                "composerY": $0.composerFrame.minY,
                "composerWidth": $0.composerFrame.width,
                "composerHeight": $0.composerFrame.height,
                "modelMenuOpen": $0.modelMenuOpen,
            ] as [String: Any]
        }
        return [
            "codexRunning": true,
            "accessibilityTrusted": AccessibilityReader.trusted(prompt: false),
            "focusedWindowFound": focusedWindow != nil,
            "windowCount": windows.count,
            "nodeCount": nodes.count,
            "roleCounts": roleCounts,
            "editableFrames": editableFrames,
            "threadMatches": threadMatches,
            "resolvedSurface": resolved as Any,
        ]
    }

    private func composerNode(nodes: [AXNode]) -> CGRect? {
        let candidates = nodes.compactMap { node -> AXNode? in
            guard ["AXTextArea", "AXTextField"].contains(node.role),
                  let frame = node.frame,
                  frame.width >= 260,
                  frame.height >= 34
            else { return nil }
            return node
        }
        guard let candidate = candidates.max(by: {
            let lhs = $0.frame ?? .zero
            let rhs = $1.frame ?? .zero
            let lhsScore = lhs.width * max(40, lhs.height) + lhs.minY * 2
            let rhsScore = rhs.width * max(40, rhs.height) + rhs.minY * 2
            return lhsScore < rhsScore
        }) else { return nil }
        return enclosingComposerFrame(for: candidate)
    }

    private func isModelMenuOpen(nodes: [AXNode]) -> Bool {
        let openMenuLabels: Set<String> = ["模型", "推理强度", "速度", "高级"]
        let visibleLabels = Set(nodes.compactMap { node -> String? in
            guard let text = node.text,
                  openMenuLabels.contains(text),
                  let frame = node.frame,
                  frame.width > 1,
                  frame.height > 1
            else { return nil }
            return text
        })
        return visibleLabels.count >= 2
    }

    private func enclosingComposerFrame(for node: AXNode) -> CGRect? {
        guard let textFrame = node.frame else { return nil }
        var current = node.element
        var candidates: [CGRect] = []
        for _ in 0..<8 {
            guard let parent: AXUIElement = AccessibilityReader.element(
                current,
                attribute: kAXParentAttribute
            ) else { break }
            current = parent
            guard let frame = AccessibilityReader.frame(parent) else { continue }
            if frame.width >= textFrame.width,
               frame.width <= textFrame.width + 100,
               frame.height >= 74,
               frame.height <= 190 {
                candidates.append(frame)
            }
        }
        return candidates.min {
            let lhsScore = abs($0.height - 104) + abs($0.width - textFrame.width) * 0.15
            let rhsScore = abs($1.height - 104) + abs($1.width - textFrame.width) * 0.15
            return lhsScore < rhsScore
        } ?? textFrame
    }

    private func inferredComposerFrame(windowFrame: CGRect) -> CGRect {
        let sideInset = max(18, windowFrame.width * 0.14)
        let bottomInset = min(44, max(12, windowFrame.height * 0.09))
        let height = min(126, max(88, windowFrame.height * 0.27))
        return CGRect(
            x: windowFrame.minX + sideInset,
            y: windowFrame.maxY - bottomInset - height,
            width: max(280, windowFrame.width - sideInset * 2),
            height: height
        )
    }

    private func selectedThread(
        nodes: [AXNode],
        window: AXUIElement
    ) -> ThreadIndexEntry? {
        let entries = store.allEntries
        guard !entries.isEmpty else { return nil }
        let byName = Dictionary(grouping: entries, by: { $0.name })
        let windowFrame = AccessibilityReader.frame(window) ?? .zero
        let matches = nodes.compactMap { node -> (ThreadIndexEntry, Int)? in
            guard let text = node.text,
                  let candidates = byName[text],
                  let entry = candidates.max(by: {
                      ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
                  })
            else { return nil }
            var score = 0
            if node.selected { score += 100 }
            if node.role == "AXStaticText" { score += 15 }
            if let frame = node.frame {
                if frame.minX > windowFrame.minX + min(260, windowFrame.width * 0.22) {
                    score += 40
                }
                if frame.minY < windowFrame.minY + 150 { score += 20 }
            }
            return (entry, score)
        }
        return matches.max(by: { $0.1 < $1.1 })?.0
    }
}

private final class MeterViewModel: ObservableObject {
    @Published var snapshot: ContextSnapshot?
    @Published var accountQuota: AccountQuotaSnapshot?
    @Published var automaticHandoffStatus = "inactive"
    @Published var automaticHandoffTriggerPercent: Double?
    @Published private(set) var automaticHandoffThreshold: Double
    @Published private(set) var automaticHandoffEnabled: Bool
    @Published var isExpanded = false
    @Published var statusText = "等待 Codex 对话"
    private var hoverGeneration = UUID()

    init() {
        let stored = UserDefaults.standard.object(forKey: automaticHandoffThresholdDefaultsKey)
            .flatMap { $0 as? Double }
        automaticHandoffThreshold = MeterViewModel.normalizedThreshold(
            stored ?? defaultAutomaticHandoffThreshold
        )
        automaticHandoffEnabled = UserDefaults.standard.object(
            forKey: automaticHandoffEnabledDefaultsKey
        ) as? Bool ?? true
    }

    func setAutomaticHandoffThreshold(_ value: Double) {
        let normalized = MeterViewModel.normalizedThreshold(value)
        automaticHandoffThreshold = normalized
        UserDefaults.standard.set(normalized, forKey: automaticHandoffThresholdDefaultsKey)
    }

    func restoreDefaultAutomaticHandoffThreshold() {
        setAutomaticHandoffThreshold(defaultAutomaticHandoffThreshold)
    }

    func setAutomaticHandoffEnabled(_ enabled: Bool) {
        automaticHandoffEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: automaticHandoffEnabledDefaultsKey)
    }

    private static func normalizedThreshold(_ value: Double) -> Double {
        min(95, max(50, (value / 5).rounded() * 5))
    }

    func setHovered(_ hovered: Bool) {
        if hovered {
            hoverGeneration = UUID()
            isExpanded = true
            return
        }
        let generation = UUID()
        hoverGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard self?.hoverGeneration == generation else { return }
            self?.isExpanded = false
        }
    }
}

private struct ContextMeterToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color(hex: 0xE6F6DF) : Color(hex: 0xE8EAED))
                .overlay(
                    Capsule().stroke(
                        configuration.isOn ? Color(hex: 0xB9E5A5) : Color(hex: 0xC9CDD3),
                        lineWidth: 1
                    )
                )
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color(hex: 0x78C850) : Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 32, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自动创建新任务")
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

private struct Segment {
    let label: String
    let value: Int64
    let color: Color
}

private struct MeterPillView: View {
    @ObservedObject var model: MeterViewModel
    let onToggle: () -> Void

    private var tint: Color {
        guard let percent = model.snapshot?.usedPercent else { return Color(hex: 0xB6BDC8) }
        if percent >= 90 { return Color(hex: 0xEF5B5B) }
        if percent >= 75 { return Color(hex: 0xF0B44D) }
        return Color(hex: 0x18B893)
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.14), lineWidth: 2.4)
                Circle()
                    .trim(from: 0, to: min(1, (model.snapshot?.usedPercent ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 12, height: 12)
                if let icon = WhaleIconLoader.image {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 17, height: 17)
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: model.setHovered)
        .help(model.snapshot.map {
            "\(TokenFormatter.percent($0.usedPercent)) · \(TokenFormatter.compact($0.usage.totalTokens)) / \(TokenFormatter.compact($0.contextWindow)) 上下文已使用"
        } ?? model.statusText)
    }
}

private struct MetricRow: View {
    let color: Color
    let label: String
    let value: String
    var secondary: String? = nil
    var explanation: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.82))
            if let explanation {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .help(explanation)
            }
            Spacer(minLength: 8)
            if let secondary {
                Text(secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.82))
                .monospacedDigit()
        }
    }
}

private struct MeterDetailsView: View {
    @ObservedObject var model: MeterViewModel
    let onClose: () -> Void

    private var segments: [Segment] {
        guard let usage = model.snapshot?.usage else { return [] }
        return [
            Segment(label: "新输入", value: usage.freshInputTokens, color: Color(hex: 0x7357FF)),
            Segment(label: "缓存输入", value: usage.cachedInputTokens, color: Color(hex: 0x4B8EFF)),
            Segment(label: "普通输出", value: usage.regularOutputTokens, color: Color(hex: 0xF0B44D)),
            Segment(label: "推理输出", value: usage.reasoningOutputTokens, color: Color(hex: 0x18B893)),
        ]
        .filter { $0.value > 0 }
    }

    private func explanation(for label: String) -> String? {
        switch label {
        case "新输入":
            return "本轮需要模型重新读取和处理的输入 Token。"
        case "缓存输入":
            return "与之前内容重复、由系统缓存复用的输入 Token，通常处理更快。"
        case "普通输出":
            return "最终显示在对话中的回答 Token。"
        case "推理输出":
            return "模型在生成答案前用于内部推理的 Token。"
        default:
            return nil
        }
    }

    private func modelDisplayName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "gpt-5.3-codex-spark":
            return "GPT-5.3 Codex Spark"
        case "gpt-5.6-sol":
            return "GPT-5.6 Sol"
        case "gpt-5.6-terra":
            return "GPT-5.6 Terra"
        default:
            return raw
        }
    }

    private func resetText(_ date: Date?) -> String? {
        date.map { "重置 \($0.formatted(date: .omitted, time: .shortened))" }
    }

    private func handoffStatusText(_ status: String) -> String {
        switch status {
        case "waiting_for_task_completion": return "等待当前任务"
        case "creating": return "正在交接"
        case "completed": return "已完成"
        case "failed": return "失败待重试"
        case "retry_wait": return "等待重试"
        case "pending": return "待交接"
        case "disabled": return "已关闭"
        default: return "未触发"
        }
    }

    var body: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("上下文窗口")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TokenFormatter.percent(snapshot.usedPercent))
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("上下文已用  \(TokenFormatter.compact(snapshot.usage.totalTokens)) / \(TokenFormatter.compact(snapshot.contextWindow))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }

                GeometryReader { geometry in
                    HStack(spacing: 1.5) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(segment.color)
                                .frame(width: max(
                                    2,
                                    geometry.size.width
                                        * CGFloat(Double(segment.value) / Double(snapshot.contextWindow))
                                ))
                        }
                        Spacer(minLength: 0)
                    }
                    .background(Color.black.opacity(0.09), in: Capsule())
                    .clipShape(Capsule())
                }
                .frame(height: 7)

                MetricRow(
                    color: Color(hex: 0x18B893),
                    label: "上下文剩余",
                    value: TokenFormatter.percent(snapshot.remainingPercent),
                    secondary: TokenFormatter.compact(snapshot.remainingTokens)
                )
                MetricRow(
                    color: Color(hex: 0xF0B44D),
                    label: "自动创建新任务",
                    value: handoffStatusText(model.automaticHandoffStatus),
                    secondary: model.automaticHandoffTriggerPercent.map {
                        "已于 \(TokenFormatter.percent($0)) 触发"
                    } ?? "阈值 \(Int(model.automaticHandoffThreshold))%",
                    explanation: "只按已用上下文比例触发，绝不按剩余比例。达到设置阈值后等待当前任务完成，再保存交接包并创建新任务；读取不到精确比例时不触发。"
                )
                HStack(spacing: 8) {
                    Text("自动创建新任务")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Toggle(
                        "自动创建新任务",
                        isOn: Binding(
                            get: { model.automaticHandoffEnabled },
                            set: { model.setAutomaticHandoffEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(ContextMeterToggleStyle())
                }
                HStack(spacing: 8) {
                    Text("新任务阈值")
                        .font(.system(size: 11.5))
                    Slider(
                        value: Binding(
                            get: { model.automaticHandoffThreshold },
                            set: { model.setAutomaticHandoffThreshold($0) }
                        ),
                        in: 50...95,
                        step: 5
                    )
                    .controlSize(.small)
                    Text("已用 \(Int(model.automaticHandoffThreshold))%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 55, alignment: .trailing)
                    if model.automaticHandoffThreshold != defaultAutomaticHandoffThreshold {
                        Button("恢复 80%") {
                            model.restoreDefaultAutomaticHandoffThreshold()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: 0x4B8EFF))
                    }
                }

                if let task = snapshot.taskEstimate {
                    Divider().opacity(0.6)
                    Text("当前任务")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    VStack(spacing: 9) {
                        MetricRow(
                            color: Color(hex: 0x4B8EFF),
                            label: "已运行",
                            value: TokenFormatter.duration(task.elapsedSeconds)
                        )
                        MetricRow(
                            color: Color(hex: 0x7357FF),
                            label: "预计完成",
                            value: task.estimatedCompletionAt.map {
                                "约 \($0.formatted(date: .omitted, time: .shortened))"
                            } ?? "暂无法可靠估算",
                            secondary: task.confidence.map { "可信度 \($0)" },
                            explanation: task.sampleCount >= 2
                                ? "根据同一对话最近 \(task.sampleCount) 个已完成任务的真实耗时估算，不是 Codex 官方承诺。"
                                : "当前对话的历史完成样本不足，暂不生成时间。"
                        )
                    }
                }

                Divider().opacity(0.6)

                VStack(spacing: 9) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        MetricRow(
                            color: segment.color,
                            label: segment.label,
                            value: TokenFormatter.compact(segment.value),
                            explanation: explanation(for: segment.label)
                        )
                    }
                }

                if let modelName = snapshot.modelName {
                    MetricRow(
                        color: Color(hex: 0x9BA4B3),
                        label: "模型",
                        value: modelDisplayName(modelName),
                        explanation: "本次对话当前使用的模型名称，不代表账户总额度。"
                    )
                }

                if let quota = model.accountQuota, quota.hasDisplayableValue {
                    Divider().opacity(0.6)
                    Text("设置额度")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    VStack(spacing: 9) {
                        if let individual = quota.individualLimit {
                            MetricRow(
                                color: Color(hex: 0x18B893),
                                label: "额度剩余",
                                value: TokenFormatter.quotaPercent(individual.remainingPercent),
                                secondary: "\(individual.used) / \(individual.limit)",
                                explanation: "来自 Codex 设置的个人额度：已用 / 总额。"
                            )
                        }
                        if let primary = quota.primary {
                            MetricRow(
                                color: Color(hex: 0x18B893),
                                label: QuotaLabel.remaining(
                                    for: primary,
                                    fallback: "短时额度剩余"
                                ),
                                value: TokenFormatter.quotaPercent(primary.remainingPercent),
                                secondary: resetText(primary.resetsAt),
                                explanation: "来自 Codex 设置的短时或周期额度。"
                            )
                        }
                        if let secondary = quota.secondary {
                            MetricRow(
                                color: Color(hex: 0x4B8EFF),
                                label: QuotaLabel.remaining(
                                    for: secondary,
                                    fallback: "长期额度剩余"
                                ),
                                value: TokenFormatter.quotaPercent(secondary.remainingPercent),
                                secondary: resetText(secondary.resetsAt),
                                explanation: "来自 Codex 设置的长期额度。"
                            )
                        }
                        if let balance = quota.creditBalance {
                            MetricRow(
                                color: Color(hex: 0xF0B44D),
                                label: "额外购买额度",
                                value: balance,
                                explanation: "账户额外购买或获赠的可用额度；0 不影响上面的周期额度。"
                            )
                        }
                        if let count = quota.availableResetCredits, count > 0 {
                            MetricRow(
                                color: Color(hex: 0x9BA4B3),
                                label: "可用重置次数",
                                value: "\(count)"
                            )
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(Color(hex: 0x18B893))
                    Text("真实只读数据 · \(snapshot.threadName)")
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondary)
            }
            .padding(15)
            .frame(width: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.black.opacity(0.10), lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
            .onHover(perform: model.setHovered)
        }
    }
}

private struct MeterPreviewView: View {
    @ObservedObject var model: MeterViewModel

    var body: some View {
        ZStack {
            Color(hex: 0xF4F5F7)
            VStack(alignment: .trailing, spacing: 10) {
                MeterDetailsView(model: model, onClose: {})
                MeterPillView(model: model, onToggle: {})
                    .padding(.trailing, 10)
            }
            .padding(22)
        }
        .frame(width: 380, height: 580)
    }
}

private struct ResetToastView: View {
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(Color(hex: 0x18B893))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(width: 320, height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 14, y: 7)
    }
}

private final class OverlayController {
    let model: MeterViewModel
    private let pillPanel: NSPanel
    private let detailsPanel: NSPanel
    private let toastPanel: NSPanel
    private var anchorFrame = CGRect.zero
    private var modelMenuOpen = false
    private var toastGeneration = UUID()

    init(model: MeterViewModel) {
        self.model = model
        pillPanel = OverlayController.makePanel(size: NSSize(width: 32, height: 28))
        detailsPanel = OverlayController.makePanel(size: NSSize(width: 330, height: 550))
        toastPanel = OverlayController.makePanel(size: NSSize(width: 320, height: 62))

        pillPanel.contentView = NSHostingView(rootView: MeterPillView(
            model: model,
            onToggle: { [weak model] in model?.isExpanded.toggle() }
        ))
        detailsPanel.contentView = NSHostingView(rootView: MeterDetailsView(
            model: model,
            onClose: { [weak model] in model?.isExpanded = false }
        ))
    }

    func update(anchor: CGRect, modelMenuOpen: Bool) {
        anchorFrame = anchor
        self.modelMenuOpen = modelMenuOpen
        positionPanels()
        pillPanel.orderFrontRegardless()
        detailsPanel.setIsVisible(model.isExpanded)
        if model.isExpanded { detailsPanel.orderFrontRegardless() }
    }

    func updatePosition(anchor: CGRect) {
        anchorFrame = anchor
        positionPanels()
    }

    func syncExpandedState() {
        detailsPanel.setIsVisible(model.isExpanded && pillPanel.isVisible)
        if model.isExpanded {
            positionPanels()
            detailsPanel.orderFrontRegardless()
        }
    }

    func hide() {
        pillPanel.orderOut(nil)
        detailsPanel.orderOut(nil)
        toastPanel.orderOut(nil)
    }

    func showNotice(title: String, body: String) {
        let generation = UUID()
        toastGeneration = generation
        toastPanel.contentView = NSHostingView(rootView: ResetToastView(title: title, message: body))
        positionToast()
        toastPanel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard self?.toastGeneration == generation else { return }
            self?.toastPanel.orderOut(nil)
        }
    }

    private func positionPanels() {
        guard let screen = NSScreen.screens.first(where: {
            let topLeftFrame = CGRect(
                x: $0.frame.minX,
                y: NSScreen.screens.map(\.frame.maxY).max()! - $0.frame.maxY,
                width: $0.frame.width,
                height: $0.frame.height
            )
            return topLeftFrame.intersects(anchorFrame)
        }) ?? NSScreen.main else { return }

        let globalTop = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        let pillSize = pillPanel.frame.size
        let horizontalInset: CGFloat = modelMenuOpen ? 305 : 245
        let pillX = min(
            screen.visibleFrame.maxX - pillSize.width - 8,
            max(screen.visibleFrame.minX + 8, anchorFrame.maxX - horizontalInset)
        )
        let insideComposer = globalTop - anchorFrame.maxY + 37 - pillSize.height
        let pillY = max(screen.visibleFrame.minY + 6, insideComposer)
        pillPanel.setFrameOrigin(NSPoint(x: pillX, y: pillY))

        let detailSize = detailsPanel.frame.size
        let detailX = min(
            screen.visibleFrame.maxX - detailSize.width - 8,
            max(screen.visibleFrame.minX + 8, pillX + pillSize.width - detailSize.width)
        )
        let detailY = min(
            screen.visibleFrame.maxY - detailSize.height - 8,
            pillY + pillSize.height + 8
        )
        detailsPanel.setFrameOrigin(NSPoint(x: detailX, y: detailY))
        positionToast()
    }

    private func positionToast() {
        guard let screen = NSScreen.main else { return }
        let toastSize = toastPanel.frame.size
        let toastX = min(
            screen.visibleFrame.maxX - toastSize.width - 8,
            max(screen.visibleFrame.minX + 8, pillPanel.frame.maxX - toastSize.width)
        )
        let toastY = min(
            screen.visibleFrame.maxY - toastSize.height - 8,
            pillPanel.frame.maxY + 8
        )
        toastPanel.setFrameOrigin(NSPoint(x: toastX, y: toastY))
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        return panel
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = MeterViewModel()
    private let store = ThreadStore()
    private let rolloutReader = RolloutReader()
    private let accountReader = CodexAccountReader()
    private let handoffClient = CodexHandoffClient()
    private var surfaceReader: CodexSurfaceReader!
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var positionTimer: Timer?
    private var lastDiagnosticSignature: String?
    private var lastQuotaRefresh = Date.distantPast
    private var accountFetchInFlight = false
    private var lastAccountError: String?
    private var handoffThreadsInFlight = Set<String>()
    private var handoffStatusByThread: [String: String] = [:]
    private var lastSurface: CodexSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        surfaceReader = CodexSurfaceReader(store: store)
        overlay = OverlayController(model: model)
        createStatusMenu()
        requestNotificationPermission()
        _ = AccessibilityReader.trusted(prompt: true)

        model.$isExpanded
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.overlay.syncExpandedState() }
            .store(in: &subscriptions)

        refresh()
        refreshAccountQuotaIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.refreshAccountQuotaIfNeeded()
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshOverlayPosition()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        positionTimer?.invalidate()
    }

    private var subscriptions = Set<AnyCancellable>()

    private func createStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "chart.pie.fill",
            accessibilityDescription: "Codex 上下文用量"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let snapshot = model.snapshot {
            let summary = NSMenuItem(
                title: "上下文已用 \(TokenFormatter.percent(snapshot.usedPercent)) · 剩余 \(TokenFormatter.compact(snapshot.remainingTokens))",
                action: nil,
                keyEquivalent: ""
            )
            summary.isEnabled = false
            menu.addItem(summary)
        }
        menu.addItem(.separator())
        if !AccessibilityReader.trusted(prompt: false) {
            menu.addItem(withTitle: "打开辅助功能设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        }
        menu.addItem(withTitle: "退出上下文仪表", action: #selector(quit), keyEquivalent: "q")
    }

    private func refresh() {
        let isCodexFrontmost =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleIdentifier
        guard isCodexFrontmost else {
            lastSurface = nil
            writeDiagnostic(accessibilityTrusted: AccessibilityReader.trusted(prompt: false))
            overlay.hide()
            return
        }
        guard AccessibilityReader.trusted(prompt: false) else {
            model.statusText = "需要开启辅助功能权限"
            model.snapshot = nil
            writeDiagnostic(accessibilityTrusted: false)
            overlay.hide()
            return
        }
        guard let surface = surfaceReader.currentSurface(),
              let rollout = store.rolloutURL(threadId: surface.thread.id),
              let snapshot = rolloutReader.snapshot(
                  from: rollout,
                  threadId: surface.thread.id,
                  threadName: surface.thread.name
              )
        else {
            lastSurface = nil
            model.statusText = "当前对话没有可验证用量"
            model.snapshot = nil
            writeDiagnostic(accessibilityTrusted: true)
            overlay.hide()
            return
        }

        notifyIfNeeded(snapshot)
        considerAutomaticHandoff(snapshot: snapshot, rolloutURL: rollout)
        model.automaticHandoffStatus =
            handoffStatusByThread[snapshot.threadId] ?? automaticHandoffStoredStatus(
                threadId: snapshot.threadId
            )
        model.automaticHandoffTriggerPercent = automaticHandoffTriggerPercent(
            threadId: snapshot.threadId
        )
        model.snapshot = snapshot
        lastSurface = surface
        model.statusText = "\(snapshot.threadName) · \(TokenFormatter.percent(snapshot.usedPercent))"
        overlay.update(
            anchor: surface.composerFrame,
            modelMenuOpen: surface.modelMenuOpen
        )
        writeDiagnostic(accessibilityTrusted: true, snapshot: snapshot)
    }

    private func refreshOverlayPosition() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleIdentifier,
              AccessibilityReader.trusted(prompt: false),
              let surface = lastSurface,
              let composerFrame = surfaceReader.translatedComposerFrame(from: surface)
        else { return }
        overlay.updatePosition(anchor: composerFrame)
    }

    private func refreshAccountQuotaIfNeeded() {
        guard !accountFetchInFlight,
              Date().timeIntervalSince(lastQuotaRefresh) >= 5 * 60
        else { return }
        accountFetchInFlight = true
        lastQuotaRefresh = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.accountReader.fetch() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.accountFetchInFlight = false
                switch result {
                case .success(let quota):
                    self.model.accountQuota = quota
                    self.lastAccountError = nil
                    self.notifyAccountResetIfNeeded(quota)
                    self.overlay.syncExpandedState()
                case .failure(let error):
                    self.lastAccountError = error.localizedDescription
                }
                self.writeDiagnostic(
                    accessibilityTrusted: AccessibilityReader.trusted(prompt: false),
                    snapshot: self.model.snapshot
                )
            }
        }
    }

    private func writeDiagnostic(
        accessibilityTrusted: Bool,
        snapshot: ContextSnapshot? = nil
    ) {
        let signature = [
            "\(accessibilityTrusted)",
            "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleIdentifier)",
            snapshot?.threadId ?? "",
            "\(snapshot?.usage.totalTokens ?? -1)",
            "\(snapshot?.contextWindow ?? -1)",
            "\(snapshot?.taskEstimate?.startedAt.timeIntervalSince1970 ?? -1)",
            "\(snapshot?.taskEstimate?.estimatedCompletionAt?.timeIntervalSince1970 ?? -1)",
            "\(model.accountQuota?.primary?.usedPercent ?? -1)",
            "\(model.accountQuota?.secondary?.usedPercent ?? -1)",
            model.accountQuota?.individualLimit?.used ?? "",
            model.accountQuota?.creditBalance ?? "",
            lastAccountError ?? "",
            handoffStatusByThread[snapshot?.threadId ?? ""] ?? "",
        ].joined(separator: "|")
        guard signature != lastDiagnosticSignature else { return }
        lastDiagnosticSignature = signature
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Context Meter",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var payload: [String: Any] = [
            "accessibilityTrusted": accessibilityTrusted,
            "codexFrontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == codexBundleIdentifier,
            "surfaceFound": snapshot != nil,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let snapshot {
            payload["threadId"] = snapshot.threadId
            payload["usedTokens"] = snapshot.usage.totalTokens
            payload["contextWindow"] = snapshot.contextWindow
            payload["usedPercent"] = snapshot.usedPercent
            if let task = snapshot.taskEstimate {
                payload["taskStartedAt"] = ISO8601DateFormatter().string(from: task.startedAt)
                payload["taskElapsedSeconds"] = task.elapsedSeconds
                payload["taskEstimateSampleCount"] = task.sampleCount
                if let estimated = task.estimatedCompletionAt {
                    payload["taskEstimatedCompletionAt"] = ISO8601DateFormatter().string(
                        from: estimated
                    )
                }
                if let confidence = task.confidence {
                    payload["taskEstimateConfidence"] = confidence
                }
            }
            if let modelName = snapshot.modelName {
                payload["modelName"] = modelName
            }
            payload["automaticHandoffThreshold"] = model.automaticHandoffThreshold
            if let triggerPercent = automaticHandoffTriggerPercent(threadId: snapshot.threadId) {
                payload["automaticHandoffTriggerPercent"] = triggerPercent
            }
            payload["automaticHandoffStatus"] =
                handoffStatusByThread[snapshot.threadId] ?? automaticHandoffStoredStatus(
                    threadId: snapshot.threadId
                )
        }
        if let quota = model.accountQuota {
            var account: [String: Any] = [
                "sampledAt": ISO8601DateFormatter().string(from: quota.sampledAt),
            ]
            if let name = quota.limitName { account["limitName"] = name }
            if let primary = quota.primary {
                account["primaryRemainingPercent"] = primary.remainingPercent
                if let minutes = primary.durationMinutes {
                    account["primaryWindowDurationMins"] = minutes
                }
                if let resetsAt = primary.resetsAt {
                    account["primaryResetsAt"] = ISO8601DateFormatter().string(from: resetsAt)
                }
            }
            if let secondary = quota.secondary {
                account["secondaryRemainingPercent"] = secondary.remainingPercent
                if let minutes = secondary.durationMinutes {
                    account["secondaryWindowDurationMins"] = minutes
                }
                if let resetsAt = secondary.resetsAt {
                    account["secondaryResetsAt"] = ISO8601DateFormatter().string(from: resetsAt)
                }
            }
            if let individual = quota.individualLimit {
                account["individualRemainingPercent"] = individual.remainingPercent
                account["individualUsed"] = individual.used
                account["individualLimit"] = individual.limit
                account["individualResetsAt"] = ISO8601DateFormatter().string(
                    from: individual.resetsAt
                )
            }
            if let balance = quota.creditBalance { account["creditBalance"] = balance }
            if let count = quota.availableResetCredits {
                account["availableResetCredits"] = count
            }
            payload["accountQuota"] = account
        } else if let lastAccountError {
            payload["accountQuotaUnavailable"] = lastAccountError
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: directory.appendingPathComponent("status.json"),
            options: .atomic
        )
    }

    private func notifyIfNeeded(_ snapshot: ContextSnapshot) {
        let defaults = UserDefaults.standard
        let compactionKey = "lastCompaction.\(snapshot.threadId)"
        if let compaction = snapshot.lastCompactionAt {
            let previous = defaults.double(forKey: compactionKey)
            if previous == 0 {
                defaults.set(compaction.timeIntervalSince1970, forKey: compactionKey)
            } else if compaction.timeIntervalSince1970 > previous + 0.5 {
                defaults.set(compaction.timeIntervalSince1970, forKey: compactionKey)
                sendNotification(
                    title: "Codex 上下文已重置",
                    body: "\(snapshot.threadName) 已完成上下文压缩，当前使用 \(TokenFormatter.percent(snapshot.usedPercent))。"
                )
            }
        }

    }

    private func considerAutomaticHandoff(
        snapshot: ContextSnapshot,
        rolloutURL: URL
    ) {
        let defaults = UserDefaults.standard
        let pendingKey = "automaticHandoff.pending.\(snapshot.threadId)"
        let completedKey = "automaticHandoff.completed.\(snapshot.threadId)"
        let pendingNoticeKey = "automaticHandoff.pendingNotice.\(snapshot.threadId)"
        let attemptKey = "automaticHandoff.lastAttempt.\(snapshot.threadId)"
        let triggerKey = "automaticHandoff.triggerPercent.\(snapshot.threadId)"

        guard model.automaticHandoffEnabled else {
            defaults.set(false, forKey: pendingKey)
            handoffStatusByThread[snapshot.threadId] = "disabled"
            return
        }

        if !(defaults.string(forKey: completedKey) ?? "").isEmpty {
            handoffStatusByThread[snapshot.threadId] = "completed"
            return
        }
        if snapshot.usedPercent >= model.automaticHandoffThreshold {
            if !defaults.bool(forKey: pendingKey) {
                defaults.set(snapshot.usedPercent, forKey: triggerKey)
            }
            defaults.set(true, forKey: pendingKey)
        }
        guard defaults.bool(forKey: pendingKey) else {
            handoffStatusByThread[snapshot.threadId] = "inactive"
            return
        }
        if snapshot.taskEstimate != nil {
            handoffStatusByThread[snapshot.threadId] = "waiting_for_task_completion"
            if !defaults.bool(forKey: pendingNoticeKey) {
                defaults.set(true, forKey: pendingNoticeKey)
                sendNotification(
                    title: "Codex 已达到 \(Int(self.model.automaticHandoffThreshold))%，准备交接",
                    body: "\(snapshot.threadName) 将在当前任务安全完成后生成交接包并新建任务。"
                )
            }
            return
        }
        guard !handoffThreadsInFlight.contains(snapshot.threadId) else { return }
        let lastAttempt = defaults.double(forKey: attemptKey)
        guard lastAttempt == 0 || Date().timeIntervalSince1970 - lastAttempt >= 5 * 60
        else {
            handoffStatusByThread[snapshot.threadId] = "retry_wait"
            return
        }

        defaults.set(Date().timeIntervalSince1970, forKey: attemptKey)
        handoffThreadsInFlight.insert(snapshot.threadId)
        handoffStatusByThread[snapshot.threadId] = "creating"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { () -> (String, URL) in
                let package = try AutomaticHandoffBuilder.build(
                    from: rolloutURL,
                    snapshot: snapshot,
                    threshold: self.model.automaticHandoffThreshold
                )
                let handoffURL = try self.writeAutomaticHandoff(package)
                let newThreadId = try self.handoffClient.createNextThread(
                    package: package,
                    modelName: snapshot.modelName
                )
                return (newThreadId, handoffURL)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handoffThreadsInFlight.remove(snapshot.threadId)
                switch result {
                case .success(let (newThreadId, handoffURL)):
                    defaults.set(newThreadId, forKey: completedKey)
                    defaults.set(false, forKey: pendingKey)
                    self.handoffStatusByThread[snapshot.threadId] = "completed"
                    let deepLink = URL(
                        string: "codex://threads/\(newThreadId)"
                    )
                    let opened: Bool
                    if let deepLink {
                        opened = NSWorkspace.shared.open(deepLink)
                    } else {
                        opened = false
                    }
                    self.sendNotification(
                        title: opened ? "Codex 自动交接已完成" : "Codex 新任务已创建",
                        body: opened
                            ? "已保存交接包并打开下一任务。"
                            : "交接包已保存到 \(handoffURL.path)，但任务链接未能自动打开。"
                    )
                case .failure(let error):
                    self.handoffStatusByThread[snapshot.threadId] = "failed"
                    self.sendNotification(
                        title: "Codex 自动交接失败",
                        body: "\(error.localizedDescription)。交接将在 5 分钟后重试。"
                    )
                }
                if self.model.snapshot?.threadId == snapshot.threadId {
                    self.model.automaticHandoffStatus =
                        self.handoffStatusByThread[snapshot.threadId] ?? "inactive"
                    self.model.automaticHandoffTriggerPercent = self.automaticHandoffTriggerPercent(
                        threadId: snapshot.threadId
                    )
                    self.overlay.syncExpandedState()
                }
                self.writeDiagnostic(
                    accessibilityTrusted: AccessibilityReader.trusted(prompt: false),
                    snapshot: self.model.snapshot
                )
            }
        }
    }

    private func automaticHandoffTriggerPercent(threadId: String) -> Double? {
        let key = "automaticHandoff.triggerPercent.\(threadId)"
        guard let value = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return nil
        }
        let percent = value.doubleValue
        return percent > 0 && percent <= 100 ? percent : nil
    }

    private func writeAutomaticHandoff(
        _ package: AutomaticHandoffPackage
    ) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Context Meter/handoffs",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stamp = Int(Date().timeIntervalSince1970)
        let file = directory.appendingPathComponent(
            "\(package.sourceThreadId)-\(stamp).md"
        )
        try package.markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func automaticHandoffStoredStatus(threadId: String) -> String {
        let defaults = UserDefaults.standard
        if !(defaults.string(
            forKey: "automaticHandoff.completed.\(threadId)"
        ) ?? "").isEmpty {
            return "completed"
        }
        if defaults.bool(forKey: "automaticHandoff.pending.\(threadId)") {
            return "pending"
        }
        return "inactive"
    }

    private func notifyAccountResetIfNeeded(_ quota: AccountQuotaSnapshot) {
        notifyQuotaWindowReset(
            quota.primary,
            key: "account.primary",
            fallbackLabel: "短时额度"
        )
        notifyQuotaWindowReset(
            quota.secondary,
            key: "account.secondary",
            fallbackLabel: "长期额度"
        )
    }

    private func notifyQuotaWindowReset(
        _ window: QuotaWindowSnapshot?,
        key: String,
        fallbackLabel: String
    ) {
        guard let window, let resetAt = window.resetsAt else { return }
        let label = QuotaLabel.reset(for: window, fallback: fallbackLabel)
        let defaults = UserDefaults.standard
        let resetKey = "quotaResetAt.\(key)"
        let usedKey = "quotaUsedPercent.\(key)"
        let previousReset = defaults.double(forKey: resetKey)
        let previousUsed = defaults.double(forKey: usedKey)
        if previousReset > 0,
           resetAt.timeIntervalSince1970 > previousReset,
           window.usedPercent + 0.5 < previousUsed {
            sendNotification(
                title: "Codex \(label)已重置",
                body: "当前剩余 \(TokenFormatter.quotaPercent(window.remainingPercent))。"
            )
        }
        defaults.set(resetAt.timeIntervalSince1970, forKey: resetKey)
        defaults.set(window.usedPercent, forKey: usedKey)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        overlay.showNotice(title: title, body: body)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(contextMeterBundleIdentifier).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func runSelfTest() -> Int32 {
    let fixture = """
    {"timestamp":"2026-07-28T00:57:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/context-meter-test"}}
    {"timestamp":"2026-07-28T00:57:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续当前测试任务"}]}}
    {"timestamp":"2026-07-28T00:57:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已完成前置检查"}]}}
    {"timestamp":"2026-07-28T00:58:00.000Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":60000}}
    {"timestamp":"2026-07-28T00:59:30.000Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":90000}}
    {"timestamp":"2026-07-28T00:59:59.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex-spark"}}
    {"timestamp":"2026-07-28T01:00:00.000Z","type":"event_msg","payload":{"type":"context_compacted"}}
    {"timestamp":"2026-07-28T01:00:00.500Z","type":"event_msg","payload":{"type":"task_started"}}
    {"timestamp":"2026-07-28T01:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"input_tokens":70000,"cached_input_tokens":50000,"output_tokens":10000,"reasoning_output_tokens":2500,"total_tokens":80000},"model_context_window":200000}}}
    """
    let snapshot = RolloutReader().parse(
        data: Data(fixture.utf8),
        threadId: "test-thread",
        threadName: "测试任务 3"
    )
    let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-context-meter-\(UUID().uuidString).jsonl"
    )
    try? fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let handoff = snapshot.flatMap {
        try? AutomaticHandoffBuilder.build(
            from: fixtureURL,
            snapshot: $0,
            threshold: defaultAutomaticHandoffThreshold
        )
    }
    let passed = snapshot?.usage.totalTokens == 80_000
        && snapshot?.contextWindow == 200_000
        && abs((snapshot?.usedPercent ?? 0) - 40) < 0.001
        && snapshot?.remainingTokens == 120_000
        && snapshot?.usage.freshInputTokens == 20_000
        && snapshot?.modelName == "gpt-5.3-codex-spark"
        && snapshot?.lastCompactionAt != nil
        && snapshot?.taskEstimate?.sampleCount == 2
        && handoff?.cwd == "/tmp/context-meter-test"
        && handoff?.nextThreadName == "测试任务 4"
        && handoff?.markdown.contains("## 禁止事项") == true
        && handoff?.markdown.contains("继续当前测试任务") == true
        && ThreadNameSequencer.nextName(
            after: "赛博办公室开发 3",
            among: ["赛博办公室开发 2", "赛博办公室开发 4"]
        ) == "赛博办公室开发 5"
        && ThreadNameSequencer.nextName(
            after: "赛博办公室开发 4（自动交接）",
            among: ["赛博办公室开发 3", "赛博办公室开发 4"]
        ) == "赛博办公室开发 5"
    print(passed ? "CodexContextMeter self-test passed" : "CodexContextMeter self-test failed")
    return passed ? 0 : 1
}

private func cachedAccountQuota() -> AccountQuotaSnapshot? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/Codex Context Meter/status.json"
        )
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let account = JSONValue.dictionary(root["accountQuota"])
    else { return nil }

    func window(prefix: String) -> QuotaWindowSnapshot? {
        guard let remaining = JSONValue.double(
            account["\(prefix)RemainingPercent"]
        ) else { return nil }
        return QuotaWindowSnapshot(
            usedPercent: 100 - remaining,
            durationMinutes: JSONValue.int64(
                account["\(prefix)WindowDurationMins"]
            ),
            resetsAt: DateParser.iso8601(account["\(prefix)ResetsAt"])
        )
    }

    let individual: SpendQuotaSnapshot?
    if let limit = JSONValue.string(account["individualLimit"]),
       let used = JSONValue.string(account["individualUsed"]),
       let remaining = JSONValue.double(account["individualRemainingPercent"]),
       let resetsAt = DateParser.iso8601(account["individualResetsAt"]) {
        individual = SpendQuotaSnapshot(
            limit: limit,
            used: used,
            remainingPercent: remaining,
            resetsAt: resetsAt
        )
    } else {
        individual = nil
    }

    let snapshot = AccountQuotaSnapshot(
        limitName: JSONValue.string(account["limitName"]),
        primary: window(prefix: "primary"),
        secondary: window(prefix: "secondary"),
        individualLimit: individual,
        creditBalance: JSONValue.string(account["creditBalance"]),
        availableResetCredits: JSONValue.int64(account["availableResetCredits"]),
        sampledAt: DateParser.iso8601(account["sampledAt"]) ?? Date()
    )
    return snapshot.hasDisplayableValue ? snapshot : nil
}

private func renderPreview(to outputURL: URL) -> Int32 {
    let store = ThreadStore()
    let reader = RolloutReader()
    guard let entry = store.mostRecentlyWrittenThread(maxAge: 60 * 60 * 24 * 30),
          let rollout = store.rolloutURL(threadId: entry.id),
          let snapshot = reader.snapshot(
              from: rollout,
              threadId: entry.id,
              threadName: entry.name
          )
    else {
        print("No real Codex context snapshot is available for preview")
        return 1
    }
    let model = MeterViewModel()
    model.snapshot = snapshot
    model.accountQuota = cachedAccountQuota()
    model.statusText = "\(snapshot.threadName) · \(TokenFormatter.percent(snapshot.usedPercent))"
    model.isExpanded = true
    let hosting = NSHostingView(rootView: MeterPreviewView(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 580)
    hosting.layoutSubtreeIfNeeded()
    guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("Unable to create preview bitmap")
        return 1
    }
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        print("Unable to encode preview PNG")
        return 1
    }
    do {
        try png.write(to: outputURL, options: .atomic)
        print(outputURL.path)
        return 0
    } catch {
        print("Unable to write preview: \(error.localizedDescription)")
        return 1
    }
}

private func printAccessibilityDiagnostic() -> Int32 {
    let report = CodexSurfaceReader(store: ThreadStore()).diagnosticReport()
    guard let data = try? JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    ), let output = String(data: data, encoding: .utf8) else {
        return 1
    }
    print(output)
    return 0
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--diagnose-accessibility") {
    exit(printAccessibilityDiagnostic())
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1) {
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])
    exit(renderPreview(to: outputURL))
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()

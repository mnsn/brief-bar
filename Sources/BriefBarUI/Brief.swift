import BriefBarCore
import Combine
import Foundation

/// What to ask Apple Intelligence's on-device model for one line of a brief.
package struct BriefRequest: Hashable, Sendable {
    package var prompt: String
    package var instructions: String
    /// Kept before what the model writes, such as the chat's name: "Avery Quinn: ".
    package var lead: String

    package init(prompt: String, instructions: String, lead: String = "") {
        self.prompt = prompt
        self.instructions = instructions
        self.lead = lead
    }
}

/// One line of a brief across sources: one thing, said in a sentence, which opens it.
package struct BriefLine: Identifiable {
    /// Changes when what it says should, such as a chat's new message.
    package var id: String
    package var source: SourceID
    package var state: ItemState
    package var date: Date?
    /// BriefBar's own words, used as they are without Apple Intelligence, or when it fails.
    package var sentence: String
    /// For the on-device model, or nil to keep the sentence. Its source decides, by its own settings: a chat's text
    /// goes in only while Teams shows message previews and summaries.
    package var request: BriefRequest?
    /// What the on-device model already wrote for it, such as the summary Teams' list shows, so that it's said the
    /// same way, and not asked for again.
    package var written: String?
    package var open: @MainActor () -> Void

    package init(
        id: String, source: SourceID, state: ItemState, date: Date?, sentence: String, request: BriefRequest? = nil,
        written: String? = nil, open: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.date = date
        self.sentence = sentence
        self.request = request
        self.written = written
        self.open = open
    }
}

package enum Briefing {
    /// The few lines worth reading first, at most `limit`, so that the brief covers every source with something to say:
    /// each source's most pressing line, then the newest of each state not in it yet, then the most pressing of the
    /// rest. Most pressing is what needs you, then what's wrong, then what's done or ready, the newest first; that's
    /// the order they show in too. What's running isn't in it.
    package static func pick(_ lines: [BriefLine], limit: Int = 5) -> [BriefLine] {
        let states: [ItemState] = [.needsYou, .failing, .done]
        let ranked = lines.enumerated()
            .filter { states.contains($0.element.state) }
            .sorted { lhs, rhs in
                let (left, right) = (states.firstIndex(of: lhs.element.state) ?? 0, states.firstIndex(of: rhs.element.state) ?? 0)
                if left != right { return left < right }
                switch (lhs.element.date, rhs.element.date) {
                case let (newer?, older?) where newer != older: return newer > older
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
        var picked: [BriefLine] = []
        func take(_ line: BriefLine?) {
            guard let line, picked.count < limit, !picked.contains(where: { $0.id == line.id }) else { return }
            picked.append(line)
        }
        var sources: [SourceID] = []
        for line in ranked where !sources.contains(line.source) {
            sources.append(line.source)
            take(line)
        }
        for state in states where !picked.contains(where: { $0.state == state }) {
            take(ranked.first { $0.state == state })
        }
        ranked.forEach(take)
        return ranked.filter { line in picked.contains { $0.id == line.id } }
    }
}

extension Briefing {
    /// What the Overview widget says: the brief's first line, then the newest of what needs you, up to `rows`, without
    /// that line again, and how many more need you.
    package static func widgetLines(_ lines: [BriefLine], rows: Int) -> (first: BriefLine?, needsYou: [BriefLine], more: Int) {
        let first = pick(lines).first
        let needsYou = pick(lines.filter { $0.state == .needsYou }, limit: .max).filter { $0.id != first?.id }
        return (first, Array(needsYou.prefix(rows)), max(needsYou.count - rows, 0))
    }
}

/// Words a brief's lines with Apple Intelligence's on-device model, on this Mac: nothing leaves it, and what it writes
/// stays in memory, for lines shown in the last few minutes, never on disk or in the log. The model words the lines
/// BriefBar picked; it doesn't decide what matters.
@MainActor
package final class BriefWriter: ObservableObject {
    @Published private var results: [BriefRequest: String] = [:]
    private var failed: Set<BriefRequest> = []
    private var queue: [BriefRequest] = []
    private var isWorking = false
    /// When each line was last on screen: what it wrote is kept that long, for lists and pages that show it again.
    private var lastShown: [BriefRequest: Date] = [:]
    private static let keepFor: TimeInterval = 600
    /// Off while BriefBar draws pictures that shouldn't wait for the model (`--render`): lines keep their sentences.
    package var isEnabled: Bool

    package init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    package var isAvailable: Bool { OnDeviceModel.isAvailable }

    /// What a line says: what the model wrote, once it has, or BriefBar's own sentence; and whether the model wrote it.
    package func text(for line: BriefLine) -> (text: String, isWritten: Bool) {
        if let written = line.written { return (written, true) }
        guard let request = line.request, let written = results[request] else { return (line.sentence, false) }
        return (request.lead + written, true)
    }

    /// Asks the model for the lines on screen that need it, and forgets what it wrote for lines no longer shown.
    package func write(_ lines: [BriefLine], now: Date = Date()) {
        let requests = lines.compactMap(\.request)
        for request in requests { lastShown[request] = now }
        lastShown = lastShown.filter { now.timeIntervalSince($0.value) < Self.keepFor }
        let kept = Set(lastShown.keys)
        if results.keys.contains(where: { !kept.contains($0) }) {
            results = results.filter { kept.contains($0.key) }
        }
        failed = failed.intersection(kept)
        queue.removeAll { !kept.contains($0) }
        guard isEnabled, isAvailable else { return }
        for request in requests.reversed() where results[request] == nil && !failed.contains(request) && !queue.contains(request) {
            queue.insert(request, at: 0)
        }
        runNext()
    }

    /// Whether every line that asked has its words, or the model couldn't (for `--render`).
    package func isDone(with lines: [BriefLine]) -> Bool {
        lines.compactMap(\.request).allSatisfy { results[$0] != nil || failed.contains($0) }
    }

    private func runNext() {
        guard !isWorking, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        isWorking = true
        Task {
            switch await OnDeviceModel.respond(to: next.prompt, instructions: next.instructions, maximumTokens: 90) {
            case .success(let text):
                if let line = Self.clean(text) { results[next] = line } else { failed.insert(next) }
            case .failure(let failure):
                Log.app.info("The brief's line stays in BriefBar's own words: \(String(describing: failure), privacy: .public)")
                failed.insert(next)
            }
            isWorking = false
            runNext()
        }
    }

    /// One line, without wrapping quotes, labels or markdown.
    nonisolated static func clean(_ text: String) -> String? {
        var line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for label in ["Summary:", "Update:", "Brief:"] where line.hasPrefix(label) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        if line.count > 1, let first = line.first, let last = line.last, "\"“'".contains(first), "\"”'".contains(last) {
            line = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard line.count >= 3 else { return nil }
        return line.count > 220 ? String(line.prefix(219)) + "…" : line
    }
}

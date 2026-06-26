import SwiftUI
import AppKit

/// Window that shows every tool call xHelperAlerts has seen, with the
/// decision the PreToolUse hook made (auto-approved, sent to the user, or
/// no-chime).
///
/// Backed by `~/.xhelper-alerts/command-log.jsonl` — one JSON object per
/// line. The view re-reads the file every 2 seconds while it's open.
struct CommandLogView: View {
    @State private var entries: [LogEntry] = []
    @State private var filter: DecisionFilter = .all
    @State private var search: String = ""
    @State private var sortOrder: [KeyPathComparator<LogEntry>] = [
        .init(\LogEntry.timestamp, order: .reverse)
    ]
    @State private var selection: LogEntry.ID?
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            footer
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Sections

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(DecisionFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Button {
                LogEntry.clearLog()
                entries = []
                selection = nil
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Empty the log file. This does not affect past Claude actions.")
        }
        .padding(12)
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.timestamp) { entry in
                Text(entry.shortTime)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Status", value: \.decision) { entry in
                DecisionBadge(decision: entry.decision)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Tool", value: \.tool) { entry in
                Text(entry.tool.isEmpty ? "—" : entry.tool)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(entry.tool.isEmpty ? .secondary : .primary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Detail", value: \.snippet) { entry in
                Text(entry.snippet.isEmpty ? "(no payload detail)" : entry.snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(entry.snippet.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary.opacity(0.85)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.snippet.isEmpty ? "Claude didn't expose a command, path, or pattern for this call." : entry.snippet)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No log entries yet.")
                .font(.headline)
            Text("When Claude runs a tool, it shows up here with the decision xHelperAlerts made.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(entries.count) entries · \(filtered.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("~/.xhelper-alerts/command-log.jsonl")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Data

    private var filtered: [LogEntry] {
        var rows = entries
        if filter != .all {
            rows = rows.filter { filter.matches($0.decision) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.tool.lowercased().contains(q)
                    || $0.snippet.lowercased().contains(q)
                    || $0.decision.lowercased().contains(q)
            }
        }
        return rows.sorted(using: sortOrder)
    }

    private func startPolling() {
        reload()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in reload() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func reload() {
        entries = LogEntry.loadAll()
    }
}

// MARK: - Decision badge

private struct DecisionBadge: View {
    let decision: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(textColor)
            .background(bgColor, in: Capsule())
    }

    private var label: String {
        switch decision {
        case "auto_approved":         return "Auto"
        case "pending_user_decision": return "Asked"
        case "no_chime":              return "Silent"
        default:                       return decision
        }
    }

    private var bgColor: Color {
        switch decision {
        case "auto_approved":         return .orange.opacity(0.18)
        case "pending_user_decision": return .blue.opacity(0.18)
        case "no_chime":              return .secondary.opacity(0.18)
        default:                       return .gray.opacity(0.18)
        }
    }

    private var textColor: Color {
        switch decision {
        case "auto_approved":         return .orange
        case "pending_user_decision": return .blue
        default:                       return .secondary
        }
    }
}

// MARK: - Filter

enum DecisionFilter: String, CaseIterable, Identifiable {
    case all, auto, asked, silent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:    return "All"
        case .auto:   return "Auto-approved"
        case .asked:  return "Sent to you"
        case .silent: return "Silent (Read/Grep/…)"
        }
    }
    func matches(_ decision: String) -> Bool {
        switch self {
        case .all:    return true
        case .auto:   return decision == "auto_approved"
        case .asked:  return decision == "pending_user_decision"
        case .silent: return decision == "no_chime"
        }
    }
}

// MARK: - Model

struct LogEntry: Identifiable, Decodable {
    let timestamp: String
    let tool: String
    let snippet: String
    let decision: String
    var id: String { timestamp + "|" + tool + "|" + snippet }

    var shortTime: String {
        // ISO-ish "2026-06-20T13:45:12" → "13:45:12"
        if let t = timestamp.split(separator: "T").last {
            return String(t)
        }
        return timestamp
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xhelper-alerts/command-log.jsonl")
    }

    static func loadAll() -> [LogEntry] {
        guard let data = try? Data(contentsOf: logURL),
              let str = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        var out: [LogEntry] = []
        for line in str.split(separator: "\n") {
            if line.isEmpty { continue }
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(LogEntry.self, from: lineData) {
                out.append(entry)
            }
        }
        return out
    }

    static func clearLog() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}

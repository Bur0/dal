import SwiftUI

struct ConflictView: View {
    let store: RepoStore
    let change: FileChange

    @State private var chunks: [ConflictChunk] = []
    @State private var choices: [Int: ConflictChoice] = [:]
    @State private var loadError: String?
    @State private var loaded = false
    @State private var loadedText = ""
    @State private var changedOnDisk = false

    private var conflicts: [ConflictChunk] { chunks.filter(\.isConflict) }
    private var resolvedCount: Int { conflicts.filter { choices[$0.id] != nil }.count }
    private var isDeleteConflict: Bool { ["DU", "UD", "DD", "AU", "UA"].contains(change.conflictCode ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: change) { load() }
        .onChange(of: store.refreshVersion) { _, _ in checkDisk() }
        .onKeyPress(.escape) { store.fileFocus = nil; return .handled }
    }

    private var fileURL: URL { store.url.appendingPathComponent(change.path) }

    /// Picks up edits made in an external editor. Untouched views reload silently; if choices
    /// were already made, saving is blocked until the user reloads.
    private func checkDisk() {
        guard loaded, let text = try? String(contentsOf: fileURL, encoding: .utf8), text != loadedText else { return }
        if choices.isEmpty { load() } else { changedOnDisk = true }
    }

    private func save() {
        guard let output = ConflictParser.resolve(chunks, choices: choices) else { return }
        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard current == loadedText else {
            changedOnDisk = true
            return
        }
        store.resolveConflict(change, content: output)
    }

    private func load() {
        choices = [:]
        changedOnDisk = false
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            loadedText = text
            chunks = ConflictParser.parse(text)
            loadError = nil
        } catch {
            chunks = []
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private var header: some View {
        HStack(spacing: 10) {
            ChangeIcon(kind: .conflicted)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.path).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Text(conflicts.isEmpty ? "Conflict" : "\(resolvedCount) of \(conflicts.count) conflicts resolved")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Take Whole File") {
                Button("Current (\(store.headBranch ?? "ours"))") { store.takeSide(change, ours: true) }
                Button("Incoming (theirs)") { store.takeSide(change, ours: false) }
            }
            .fixedSize()
            .controlSize(.small)
            Button("Mark Resolved") { store.markResolved(change) }
                .controlSize(.small)
                .help("Stage the file as it is on disk (after editing it yourself)")
            if !conflicts.isEmpty {
                Button("Save & Resolve") { save() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(resolvedCount < conflicts.count || changedOnDisk)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Button { store.fileFocus = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel("Close conflict view")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if changedOnDisk {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.modified)
                Text("\(change.fileName) changed on disk since you opened it. Reload to resolve the current version.")
                    .font(.system(size: 11.5))
                Spacer()
                Button("Reload") { load() }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.modified.opacity(0.12))
        }
        if isDeleteConflict && conflicts.isEmpty {
            VStack(spacing: 12) {
                EmptyState(symbol: "trash.slash", title: "Modified on one side, deleted on the other",
                           message: "Choose whether to keep the file or delete it.")
                    .frame(maxHeight: 200)
                HStack {
                    Button("Keep File") { store.markResolved(change) }
                    Button("Delete File", role: .destructive) {
                        store.run("Resolve") { try await store.git.run(["rm", "-q", "--", change.path]) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't read file", message: loadError)
        } else if loaded && conflicts.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "No conflict markers left",
                       message: "If the file looks right, mark it as resolved.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks) { chunk in
                        switch chunk.content {
                        case .text(let lines):
                            ContextBlock(lines: lines)
                        case .conflict(let ours, _, let theirs, let oursLabel, let theirsLabel):
                            ConflictBlock(ours: ours, theirs: theirs,
                                          oursLabel: oursLabel.isEmpty ? "Current" : oursLabel,
                                          theirsLabel: theirsLabel.isEmpty ? "Incoming" : theirsLabel,
                                          choice: Binding(get: { choices[chunk.id] }, set: { choices[chunk.id] = $0 }))
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.panel)
        }
    }
}

/// Shows up to 3 lines of context around conflicts; long unchanged runs are collapsed.
private struct ContextBlock: View {
    let lines: [String]
    @State private var expanded = false

    var body: some View {
        let collapsible = lines.count > 8 && !expanded
        VStack(alignment: .leading, spacing: 0) {
            if collapsible {
                linesView(Array(lines.prefix(3)))
                Button {
                    expanded = true
                } label: {
                    Text("⋯ \(lines.count - 6) unchanged lines")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(Theme.subtleFill)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                linesView(Array(lines.suffix(3)))
            } else {
                linesView(lines)
            }
        }
    }

    private func linesView(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.isEmpty ? " " : line)
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConflictBlock: View {
    let ours: [String]
    let theirs: [String]
    let oursLabel: String
    let theirsLabel: String
    @Binding var choice: ConflictChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let choice {
                resolved(choice)
            } else {
                side(title: "Current · \(oursLabel)", lines: ours, color: Theme.renamed) { choice = .ours }
                side(title: "Incoming · \(theirsLabel)", lines: theirs, color: Theme.added) { choice = .theirs }
                HStack(spacing: 8) {
                    Text("Keep both:").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Current first") { choice = .oursThenTheirs }
                    Button("Incoming first") { choice = .theirsThenOurs }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.subtleFill)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(choice == nil ? Theme.conflict.opacity(0.6) : Theme.added.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func side(title: String, lines: [String], color: Color, use: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Use This", action: use).controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(color.opacity(0.16))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(Theme.mono)
                    .padding(.leading, 16)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.07))
            }
            if lines.isEmpty {
                Text("(empty)").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 16).padding(.vertical, 3)
            }
        }
    }

    private func resolved(_ choice: ConflictChoice) -> some View {
        let lines: [String]
        let label: String
        switch choice {
        case .ours: lines = ours; label = "Using current"
        case .theirs: lines = theirs; label = "Using incoming"
        case .oursThenTheirs: lines = ours + theirs; label = "Using both (current first)"
        case .theirsThenOurs: lines = theirs + ours; label = "Using both (incoming first)"
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.added)
                Text(label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Change") { self.choice = nil }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.added.opacity(0.1))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(Theme.mono)
                    .padding(.leading, 16)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

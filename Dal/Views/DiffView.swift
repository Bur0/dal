import SwiftUI

struct DiffView: View {
    let store: RepoStore
    let focus: FileFocus

    @State private var diff: FileDiff?
    @State private var error: String?
    @State private var selection: [Int: Set<Int>] = [:]   // hunk id → selected line ids
    @State private var anchor: (hunk: Int, line: Int)?
    @AppStorage("diff.wrap") private var wrap = true
    @FocusState private var focused: Bool

    private var change: FileChange { focus.change }

    private enum Mode { case unstaged, staged, readOnly }
    private var mode: Mode {
        if case .working(let c, let staged) = focus {
            if c.kind == .untracked { return .readOnly }
            // Renames, new and deleted files can only be staged as a whole file.
            if let diff, !PatchBuilder.supportsPartial(diff.header) { return .readOnly }
            return staged ? .staged : .unstaged
        }
        return .readOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: focus) { await load(reset: true) }
        .onChange(of: store.refreshVersion) { _, _ in
            if case .working = focus { Task { await load(reset: false) } }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { store.fileFocus = nil; return .handled }
    }

    private func load(reset: Bool) async {
        do {
            let result: FileDiff
            switch focus {
            case .working(let c, let staged):
                result = try await store.git.diffWorking(c, staged: staged)
            case .commit(let sha, let parent, let c):
                result = try await store.git.diffCommit(sha: sha, parent: parent, change: c)
            case .conflict:
                result = FileDiff()
            }
            if reset || result != diff { selection = [:]; anchor = nil }
            diff = result
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ChangeIcon(kind: change.kind)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(change.directory).foregroundStyle(Theme.secondaryText)
                    Text(change.fileName).fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.head)
                if let old = change.oldPath {
                    Text("renamed from \(old)").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                }
            }
            if let diff, !diff.isBinary {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(Theme.added)
                    Text("−\(diff.deletions)").foregroundStyle(Theme.deleted)
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            Spacer()
            IconToggle(symbol: "text.word.spacing", label: "Wrap long lines", isOn: $wrap)
            if case .working(let c, let staged) = focus {
                if staged {
                    Button("Unstage File") { store.unstage(c) }.controlSize(.small)
                } else {
                    Button("Discard File", role: .destructive) { store.discard(c) }.controlSize(.small)
                    Button("Stage File") { store.stage(c) }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
            Button {
                store.openFile(change.path)
            } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Open in default editor")
                .accessibilityLabel("Open in default editor")
            Button {
                store.fileFocus = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close diff (Esc)")
            .accessibilityLabel("Close diff")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error {
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load diff", message: error)
        } else if let diff {
            if diff.isBinary {
                EmptyState(symbol: "doc.zipper", title: "Binary file", message: "Binary changes can't be shown as text.")
            } else if diff.hunks.isEmpty {
                EmptyState(symbol: "equal.circle", title: "No textual changes",
                           message: "Only the file mode or metadata changed.")
            } else {
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            hunkHeader(diff: diff, hunk: hunk)
                            ForEach(hunk.lines) { line in
                                lineRow(hunk: hunk, line: line)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .background(Theme.panel)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hunkHeader(diff: FileDiff, hunk: DiffHunk) -> some View {
        let selected = selection[hunk.id] ?? []
        let suffix = selected.isEmpty ? "Hunk" : "\(selected.count) Line\(selected.count == 1 ? "" : "s")"
        return HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            if !selected.isEmpty {
                Button("Clear") { selection[hunk.id] = nil }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            switch mode {
            case .unstaged:
                Button("Discard \(suffix)", role: .destructive) {
                    store.apply(.discard, diff: diff, hunk: hunk, lines: selected)
                }
                .controlSize(.small)
                Button("Stage \(suffix)") {
                    store.apply(.stage, diff: diff, hunk: hunk, lines: selected)
                }
                .controlSize(.small)
            case .staged:
                Button("Unstage \(suffix)") {
                    store.apply(.unstage, diff: diff, hunk: hunk, lines: selected)
                }
                .controlSize(.small)
            case .readOnly:
                if case .working = focus, change.kind != .untracked {
                    Text("Whole file only (rename / new / deleted)")
                        .font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func lineRow(hunk: DiffHunk, line: DiffLine) -> some View {
        let selected = selection[hunk.id]?.contains(line.id) ?? false
        let selectable = mode != .readOnly && line.isChange
        return HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(Theme.mutedText)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(Theme.mutedText)
            Text(marker(line))
                .frame(width: 20, alignment: .center)
                .foregroundStyle(markerColor(line))
            Text(line.kind == .noNewline ? line.text.trimmed : line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .noNewline ? Theme.mutedText : Color.primary)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .padding(.trailing, 12)
        }
        .font(Theme.mono)
        .padding(.vertical, 1.5)
        .background(lineBackground(line, selected: selected))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable else { return }
            toggle(hunk: hunk, line: line, extend: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            Button("Copy Line") { copy([line.text]) }
            if let selected = selection[hunk.id], !selected.isEmpty {
                Button("Copy Selected Lines") { copy(hunk.lines.filter { selected.contains($0.id) }.map(\.text)) }
            }
            Button("Copy Hunk") { copy(hunk.lines.filter { $0.kind != .noNewline }.map(\.text)) }
        }
    }

    private func copy(_ lines: [String]) {
        store.copy(lines.joined(separator: "\n"), label: lines.count == 1 ? "Copied line" : "Copied \(lines.count) lines")
    }

    private func toggle(hunk: DiffHunk, line: DiffLine, extend: Bool) {
        var set = selection[hunk.id] ?? []
        if extend, let anchor, anchor.hunk == hunk.id {
            let ids = hunk.lines.filter(\.isChange).map(\.id)
            let lo = min(anchor.line, line.id), hi = max(anchor.line, line.id)
            for id in ids where id >= lo && id <= hi { set.insert(id) }
        } else if set.contains(line.id) {
            set.remove(line.id)
        } else {
            set.insert(line.id)
        }
        anchor = (hunk.id, line.id)
        selection[hunk.id] = set.isEmpty ? nil : set
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private func markerColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: Theme.added
        case .deletion: Theme.deleted
        default: Theme.mutedText
        }
    }

    private func lineBackground(_ line: DiffLine, selected: Bool) -> Color {
        switch line.kind {
        case .addition: Theme.added.opacity(selected ? 0.32 : 0.13)
        case .deletion: Theme.deleted.opacity(selected ? 0.32 : 0.13)
        default: .clear
        }
    }
}

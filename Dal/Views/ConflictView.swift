import SwiftUI

/// Three-pane merge tool: Current and Incoming side by side (scrolling together), the result
/// below. Pick whole conflicts or single lines from either side; or edit the output by hand.
struct ConflictView: View {
    let store: RepoStore
    let change: FileChange

    @State private var chunks: [ConflictChunk] = []
    @State private var picks: [Int: ConflictPick] = [:]
    @State private var loadError: String?
    @State private var loaded = false
    /// The file on disk when it was opened (to notice outside edits before overwriting them).
    @State private var loadedText = ""
    @State private var changedOnDisk = false
    /// Non-nil while the output is being edited by hand; the selections above are then paused.
    @State private var manualText: String?
    @State private var focusedConflict: Int?
    @State private var scrollTarget: Int?
    @State private var confirmMarkers = false
    @AppStorage("conflict.outputHeight") private var outputHeight: Double = 240

    private var conflicts: [ConflictChunk] { chunks.filter(\.isConflict) }
    private var resolvedCount: Int { conflicts.filter { picks[$0.id]?.isResolved == true }.count }
    private var allResolved: Bool { resolvedCount == conflicts.count }
    private var isDeleteConflict: Bool { ["DU", "UD", "DD", "AU", "UA"].contains(change.conflictCode ?? "") }
    private var fileURL: URL { store.url.appendingPathComponent(change.path) }
    private var labels: ConflictLabels {
        guard case .conflict(_, _, _, let o, let t)? = conflicts.first?.content else { return ConflictLabels() }
        return ConflictLabels(ours: o.isEmpty ? "Current" : o, theirs: t.isEmpty ? "Incoming" : t)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banners
            content
        }
        .task(id: change) { await load() }
        .onChange(of: store.refreshVersion) { _, _ in checkDisk() }
        .onKeyPress(.escape) { store.fileFocus = nil; return .handled }
        #if DEBUG
        .onChange(of: store.debugConflictPick) { _, value in
            if value == "save" { save(); return }
            if let side = value?.split(separator: ":").last, value?.hasPrefix("all:") == true {
                setAll(side == "ours" ? .ours : side == "theirs" ? .theirs : .oursThenTheirs); return
            }
            let parts = (value ?? "").split(separator: ":").map(String.init)
            guard parts.count == 2, let n = Int(parts[0]), n >= 1, n <= conflicts.count,
                  case .conflict(let ours, _, let theirs, _, _) = conflicts[n - 1].content else { return }
            let choice: ConflictChoice = parts[1] == "ours" ? .ours : parts[1] == "theirs" ? .theirs : .oursThenTheirs
            picks[conflicts[n - 1].id] = ConflictPick(choice, oursCount: ours.count, theirsCount: theirs.count)
            focusedConflict = conflicts[n - 1].id
        }
        #endif
        .alert("The output still has conflict markers", isPresented: $confirmMarkers) {
            Button("Save Anyway", role: .destructive) { write(manualText ?? "") }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Lines starting with <<<<<<<, ======= and >>>>>>> would be committed as they are.")
        }
    }

    // MARK: Loading and saving

    private func load() async {
        picks = [:]
        manualText = nil
        changedOnDisk = false
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            loadedText = text
            let source = await store.git.conflictSource(path: change.path, working: text)
            chunks = ConflictParser.parse(source)
            loadError = nil
        } catch {
            chunks = []
            loadError = error.localizedDescription
        }
        focusedConflict = conflicts.first?.id
        loaded = true
    }

    /// Picks up edits made in an external editor. Untouched views reload silently; once choices
    /// were made, saving is blocked until the user reloads.
    private func checkDisk() {
        guard loaded, let text = try? String(contentsOf: fileURL, encoding: .utf8), text != loadedText else { return }
        if picks.isEmpty && manualText == nil { Task { await load() } } else { changedOnDisk = true }
    }

    private var canSave: Bool {
        guard !changedOnDisk else { return false }
        return manualText != nil || (!conflicts.isEmpty && allResolved)
    }

    private func save() {
        guard canSave else { return }
        if let manualText {
            if ConflictParser.hasMarkers(manualText) { confirmMarkers = true } else { write(manualText) }
        } else if let output = ConflictParser.resolve(chunks, picks: picks) {
            write(output)
        }
    }

    private func write(_ output: String) {
        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard current == loadedText else { changedOnDisk = true; return }
        store.resolveConflict(change, content: output)
    }

    // MARK: Navigation

    /// Next/previous conflict, preferring ones still undecided.
    private func go(_ delta: Int) {
        let ids = conflicts.map(\.id)
        guard !ids.isEmpty else { return }
        let unresolved = ids.filter { picks[$0]?.isResolved != true }
        let pool = unresolved.isEmpty ? ids : unresolved
        let current = focusedConflict ?? (delta > 0 ? -1 : Int.max)
        let next = delta > 0 ? (pool.first { $0 > current } ?? pool.first)
                             : (pool.last { $0 < current } ?? pool.last)
        if let next { focusedConflict = next; scrollTarget = next }
    }

    private func setAll(_ choice: ConflictChoice) {
        for chunk in conflicts {
            if case .conflict(let ours, _, let theirs, _, _) = chunk.content {
                picks[chunk.id] = ConflictPick(choice, oursCount: ours.count, theirsCount: theirs.count)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ChangeIcon(kind: .conflicted)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.path).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !conflicts.isEmpty && manualText == nil {
                HStack(spacing: 0) {
                    navButton("chevron.up", "Previous conflict (⌘↑)", .upArrow) { go(-1) }
                    navButton("chevron.down", "Next conflict (⌘↓)", .downArrow) { go(1) }
                }
                Menu("Resolve All") {
                    Section("Every conflict · keeps what merged cleanly") {
                        Button("Use Current (\(labels.ours))") { setAll(.ours) }
                        Button("Use Incoming (\(labels.theirs))") { setAll(.theirs) }
                        Button("Use Both, Current First") { setAll(.oursThenTheirs) }
                        Button("Clear Selections") { picks = [:] }
                    }
                    Section("Whole file · discards the other side entirely") {
                        Button("Take Current Version") { store.takeSide(change, ours: true) }
                        Button("Take Incoming Version") { store.takeSide(change, ours: false) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
            }
            Button("Mark Resolved") { store.markResolved(change) }
                .controlSize(.small)
                .help("Stage the file as it is on disk (after editing it yourself)")
            if !conflicts.isEmpty || manualText != nil {
                Button("Save & Resolve") { save() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .help(canSave ? "Write the output, stage it and open the next conflicted file (⌘S)"
                                  : "Pick a side or lines for every conflict first")
            }
            Button { store.fileFocus = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel("Close merge tool")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private var subtitle: String {
        if manualText != nil { return "Editing the output by hand" }
        if conflicts.isEmpty { return "Conflict" }
        let files = store.status.conflicted.count
        let more = files > 1 ? " · \(files) files conflicted" : ""
        return "\(resolvedCount) of \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s") resolved\(more)"
    }

    private func navButton(_ symbol: String, _ help: String, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(key, modifiers: .command)
        .help(help)
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if changedOnDisk {
            banner("exclamationmark.triangle.fill", Theme.modified,
                   "\(change.fileName) changed on disk since you opened it. Reload to resolve the current version.") {
                Button("Reload") { Task { await load() } }
            }
        }
        if manualText != nil {
            banner("pencil", Theme.secondaryText,
                   "You're editing the output by hand. The selections above are paused until you discard your edits.") {
                Button("Discard Edits") { manualText = nil }
            }
        } else if store.ongoing == .rebase && !conflicts.isEmpty {
            banner("info.circle", Theme.secondaryText,
                   "During a rebase, Current is the branch you're rebasing onto and Incoming is your commit being replayed.") {
                EmptyView()
            }
        }
    }

    private func banner<Actions: View>(_ symbol: String, _ color: Color, _ text: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(text).font(.system(size: 12)).lineLimit(2)
                Spacer()
                actions().controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.10))
            Divider()
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
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
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if conflicts.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "No conflict markers left",
                       message: "If the file looks right, mark it as resolved.")
        } else {
            GeometryReader { geo in
                let maxOutput = max(120, geo.size.height - 180)
                VStack(spacing: 0) {
                    SidesPane(chunks: chunks, picks: $picks, focused: $focusedConflict, scrollTarget: $scrollTarget,
                              labels: labels, rebasing: store.ongoing == .rebase)
                        .disabled(manualText != nil)
                        .opacity(manualText != nil ? 0.45 : 1)
                    PaneDivider(height: $outputHeight, range: 120...maxOutput)
                    OutputPane(chunks: chunks, picks: picks, manualText: $manualText,
                               jump: { id in focusedConflict = id; scrollTarget = id })
                        .frame(height: min(max(outputHeight, 120), maxOutput))
                }
            }
        }
    }
}

struct ConflictLabels {
    var ours = "Current"
    var theirs = "Incoming"
}

enum ConflictColors {
    static let ours = Theme.renamed          // blue
    static let theirs = Theme.lane(4)        // teal
}

/// Drag to resize the output pane (dragging up makes it taller).
private struct PaneDivider: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if start == nil { start = height }
                            height = min(max((start ?? height) - value.translation.height, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            .zIndex(1)
    }
}

// MARK: Current | Incoming

private struct SidesPane: View {
    let chunks: [ConflictChunk]
    @Binding var picks: [Int: ConflictPick]
    @Binding var focused: Int?
    @Binding var scrollTarget: Int?
    let labels: ConflictLabels
    let rebasing: Bool

    /// Line number each chunk starts at, on each side.
    private var starts: [Int: (ours: Int, theirs: Int)] {
        var result: [Int: (ours: Int, theirs: Int)] = [:]
        var o = 1, t = 1
        for chunk in chunks {
            result[chunk.id] = (o, t)
            switch chunk.content {
            case .text(let lines): o += lines.count; t += lines.count
            case .conflict(let ours, _, let theirs, _, _): o += ours.count; t += theirs.count
            }
        }
        return result
    }

    var body: some View {
        let starts = self.starts
        let numbers = Dictionary(uniqueKeysWithValues: chunks.filter(\.isConflict).enumerated().map { ($1.id, $0 + 1) })
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(chunks) { chunk in
                            let start = starts[chunk.id] ?? (1, 1)
                            switch chunk.content {
                            case .text(let lines):
                                SharedLines(lines: lines, oursStart: start.ours, theirsStart: start.theirs)
                            case .conflict(let ours, let base, let theirs, _, _):
                                ConflictRow(number: numbers[chunk.id] ?? 0, ours: ours, base: base, theirs: theirs,
                                            oursStart: start.ours, theirsStart: start.theirs,
                                            pick: Binding(get: { picks[chunk.id] ?? ConflictPick() },
                                                          set: { picks[chunk.id] = $0; focused = chunk.id }),
                                            focused: focused == chunk.id)
                                    .id(chunk.id)
                            }
                        }
                    } header: {
                        columnHeader
                    }
                }
                .padding(.bottom, 16)
            }
            .background(Theme.panel)
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.15)) }
                scrollTarget = nil
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            sideTitle("Current", labels.ours, rebasing ? "the branch being rebased onto" : "what you have",
                      ConflictColors.ours)
            Divider()
            sideTitle("Incoming", labels.theirs, rebasing ? "your commit being replayed" : "what's being merged in",
                      ConflictColors.theirs)
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sideTitle(_ title: String, _ label: String, _ help: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .help("\(title) · \(label) — \(help)")
    }
}

/// Unchanged lines, shown on both sides; long runs fold to three lines at each end.
private struct SharedLines: View {
    let lines: [String]
    let oursStart: Int
    let theirsStart: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.count > 8 && !expanded {
                rows(0..<3)
                FoldButton(count: lines.count - 6) { expanded = true }
                rows((lines.count - 3)..<lines.count)
            } else {
                rows(0..<lines.count)
            }
        }
    }

    private func rows(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { i in
            HStack(spacing: 0) {
                CodeLine(number: oursStart + i, text: lines[i]).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                CodeLine(number: theirsStart + i, text: lines[i]).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct FoldButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("⋯ \(count) unchanged lines")
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Theme.subtleFill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .pointingHandCursor()
    }
}

private struct CodeLine: View {
    let number: Int?
    let text: String
    var checkbox: Bool? = nil
    var tint: Color = .clear

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.mutedText)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 6)
            if let checkbox {
                Image(systemName: checkbox ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(checkbox ? tint : Theme.mutedText)
                    .frame(width: 16)
                    .padding(.trailing, 4)
            }
            Text(verbatim: display)
                .font(Theme.mono)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
    }

    private var display: String {
        var t = text
        if t.hasSuffix("\r") { t.removeLast() }
        return t.isEmpty ? " " : t.replacingOccurrences(of: "\t", with: "    ")
    }
}

/// One conflict: the two sides next to each other, every line with its own checkbox.
private struct ConflictRow: View {
    let number: Int
    let ours: [String]
    let base: [String]?
    let theirs: [String]
    let oursStart: Int
    let theirsStart: Int
    @Binding var pick: ConflictPick
    let focused: Bool
    @State private var showBase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if showBase, let base {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Base · before either side changed it")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 50).padding(.vertical, 3)
                    ForEach(Array(base.enumerated()), id: \.offset) { _, line in
                        CodeLine(number: nil, text: line).foregroundStyle(Theme.secondaryText)
                    }
                    if base.isEmpty { note("The common ancestor had no lines here") }
                }
                .padding(.bottom, 4)
                .background(Theme.subtleFill)
                .overlay(alignment: .bottom) { Divider() }
            }
            HStack(alignment: .top, spacing: 0) {
                side(lines: ours, start: oursStart, selected: pick.ours, color: ConflictColors.ours, isOurs: true)
                Divider()
                side(lines: theirs, start: theirsStart, selected: pick.theirs, color: ConflictColors.theirs, isOurs: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(focused ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.14), lineWidth: focused ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: pick.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(pick.isResolved ? Theme.added : Theme.modified)
                .font(.system(size: 12))
            Text("Conflict \(number)").font(.system(size: 11, weight: .semibold))
            Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Spacer(minLength: 4)
            if base != nil {
                Toggle("Base", isOn: $showBase)
                    .toggleStyle(.button)
                    .help("Show the lines as they were before either side changed them")
            }
            if !pick.ours.isEmpty && !pick.theirs.isEmpty {
                Button { pick.theirsFirst.toggle() } label: {
                    Label(pick.theirsFirst ? "Incoming first" : "Current first", systemImage: "arrow.up.arrow.down")
                }
                .help("Swap which side's lines come first in the output")
            }
            Button("Current") { pick = ConflictPick(.ours, oursCount: ours.count, theirsCount: theirs.count) }
                .help("Keep all of the current lines")
            Button("Incoming") { pick = ConflictPick(.theirs, oursCount: ours.count, theirsCount: theirs.count) }
                .help("Keep all of the incoming lines")
            Menu {
                Button("Both, Current First") { pick = ConflictPick(.oursThenTheirs, oursCount: ours.count, theirsCount: theirs.count) }
                Button("Both, Incoming First") { pick = ConflictPick(.theirsThenOurs, oursCount: ours.count, theirsCount: theirs.count) }
                Button("Neither (Remove These Lines)") { pick = ConflictPick(neither: true) }
                Divider()
                Button("Clear") { pick = ConflictPick() }.disabled(!pick.isResolved)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More ways to resolve this conflict")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.subtleFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusText: String {
        if pick.neither { return "Removed" }
        let o = pick.ours.count, t = pick.theirs.count
        if o == 0 && t == 0 { return "Pick lines from either side" }
        if t == 0 && o == ours.count { return "Using current" }
        if o == 0 && t == theirs.count { return "Using incoming" }
        if o == ours.count && t == theirs.count { return pick.theirsFirst ? "Both, incoming first" : "Both, current first" }
        return "\(o + t) line\(o + t == 1 ? "" : "s") picked"
    }

    private func side(lines: [String], start: Int, selected: Set<Int>, color: Color, isOurs: Bool) -> some View {
        let all = !lines.isEmpty && selected.count == lines.count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleAll(isOurs: isOurs, count: lines.count, on: !all)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: all ? "checkmark.square.fill" : selected.isEmpty ? "square" : "minus.square.fill")
                        .foregroundStyle(selected.isEmpty ? Theme.mutedText : color)
                    Text(lines.isEmpty ? "No lines on this side"
                         : lines.count == 1 ? "1 line"
                         : all ? "All \(lines.count) lines" : "\(lines.count) lines")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.leading, 44)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(lines.isEmpty)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let on = selected.contains(i)
                Button { toggle(i, isOurs: isOurs) } label: {
                    CodeLine(number: start + i, text: line, checkbox: on, tint: color)
                        .background(color.opacity(on ? 0.18 : 0.05))
                        .opacity(pick.isResolved && !on ? 0.55 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
    }

    private func toggle(_ i: Int, isOurs: Bool) {
        var p = pick
        p.neither = false
        let wasEmpty = p.ours.isEmpty && p.theirs.isEmpty
        if isOurs {
            if p.ours.contains(i) { p.ours.remove(i) } else { p.ours.insert(i) }
        } else {
            if p.theirs.contains(i) { p.theirs.remove(i) } else { p.theirs.insert(i) }
        }
        if wasEmpty { p.theirsFirst = !isOurs }   // the side picked first goes first
        pick = p
    }

    private func toggleAll(isOurs: Bool, count: Int, on: Bool) {
        var p = pick
        p.neither = false
        let wasEmpty = p.ours.isEmpty && p.theirs.isEmpty
        if isOurs { p.ours = on ? Set(0..<count) : [] } else { p.theirs = on ? Set(0..<count) : [] }
        if wasEmpty && on { p.theirsFirst = !isOurs }
        pick = p
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.mutedText).padding(.leading, 50).padding(.vertical, 3)
    }
}

// MARK: Output

/// The file as it will be saved. Undecided conflicts show as placeholders that jump to the conflict.
private struct OutputPane: View {
    let chunks: [ConflictChunk]
    let picks: [Int: ConflictPick]
    @Binding var manualText: String?
    let jump: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Output").font(.system(size: 11, weight: .semibold))
                Text(manualText == nil ? "Updates as you pick lines" : "Edited by hand")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if manualText == nil {
                    Button {
                        manualText = ConflictParser.render(chunks, picks: picks)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit the result directly; undecided conflicts keep their markers")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            if let text = manualText {
                TextEditor(text: Binding(get: { text }, set: { manualText = $0 }))
                    .font(Theme.mono)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .background(Theme.panel)
            } else {
                preview
            }
        }
    }

    private var preview: some View {
        let numbers = Dictionary(uniqueKeysWithValues: chunks.filter(\.isConflict).enumerated().map { ($1.id, $0 + 1) })
        var line = 1
        var starts: [Int: Int] = [:]
        for chunk in chunks {
            starts[chunk.id] = line
            switch chunk.content {
            case .text(let lines): line += lines.count
            case .conflict(let ours, _, let theirs, _, _):
                if let pick = picks[chunk.id], pick.isResolved { line += pick.lines(ours: ours, theirs: theirs).count }
            }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chunks) { chunk in
                    let start = starts[chunk.id] ?? 1
                    switch chunk.content {
                    case .text(let lines):
                        OutputText(lines: lines, start: start)
                    case .conflict(let ours, _, let theirs, _, _):
                        if let pick = picks[chunk.id], pick.isResolved {
                            let kept = pick.lines(ours: ours, theirs: theirs)
                            ForEach(Array(kept.enumerated()), id: \.offset) { i, item in
                                let color = item.fromOurs ? ConflictColors.ours : ConflictColors.theirs
                                CodeLine(number: start + i, text: item.line)
                                    .background(color.opacity(0.10))
                                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
                            }
                            if kept.isEmpty {
                                Text("Conflict \(numbers[chunk.id] ?? 0) removed")
                                    .font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                                    .padding(.leading, 50).padding(.vertical, 2)
                            }
                        } else {
                            Button { jump(chunk.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.modified)
                                    Text("Conflict \(numbers[chunk.id] ?? 0) — pick lines above")
                                    Spacer()
                                    Text("Go to conflict").foregroundStyle(Theme.secondaryText)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .padding(.leading, 50)
                                .padding(.trailing, 12)
                                .frame(height: 24)
                                .background(Theme.modified.opacity(0.12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Theme.panel)
    }
}

private struct OutputText: View {
    let lines: [String]
    let start: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.count > 8 && !expanded {
                rows(0..<3)
                FoldButton(count: lines.count - 6) { expanded = true }
                rows((lines.count - 3)..<lines.count)
            } else {
                rows(0..<lines.count)
            }
        }
    }

    private func rows(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { i in
            CodeLine(number: start + i, text: lines[i]).foregroundStyle(Theme.secondaryText)
        }
    }
}

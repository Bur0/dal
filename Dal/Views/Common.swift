import SwiftUI
import AppKit
import CryptoKit

// MARK: Appearance

/// Light / dark choice from Settings. Every colour in `Theme` is a dynamic NSColor, so setting the
/// app's appearance is enough — windows, sheets and the Settings window all follow at once.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "theme"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    @MainActor static func apply(_ theme: AppTheme = current) {
        NSApplication.shared.appearance = theme.appearance
    }
}

// MARK: Theme

enum Theme {
    // Every colour here is checked against WCAG on both themes: text ≥ 4.5:1, graph lines and
    // icons ≥ 3:1. The system's .secondary/.tertiary labels miss that (tertiary is ~2.3:1 on dark,
    // secondary ~3.9:1 on light), so text uses these tokens instead.

    /// Body-level secondary text: author, dates, paths. ≥ 7:1.
    static let secondaryText = dynamic(light: Color(hex: 0x4D4D4D), dark: Color.white.opacity(0.68))
    /// Meta text: SHAs, counts, hints, empty states. ≥ 5:1.
    static let mutedText = dynamic(light: Color(hex: 0x666666), dark: Color.white.opacity(0.55))

    /// Lane colours, darker on light backgrounds so lines and badge borders keep ≥ 3:1.
    static let lanes: [Color] = [
        dynamic(light: Color(hex: 0x1F6FB2), dark: Color(hex: 0x2F9BE0)), // blue
        dynamic(light: Color(hex: 0x2A8A4A), dark: Color(hex: 0x3DB46D)), // green
        dynamic(light: Color(hex: 0xA86A00), dark: Color(hex: 0xE59A2F)), // amber
        dynamic(light: Color(hex: 0xC23B36), dark: Color(hex: 0xE0534F)), // red
        dynamic(light: Color(hex: 0x0F7F7B), dark: Color(hex: 0x1FB5B0)), // teal
        dynamic(light: Color(hex: 0xB03D86), dark: Color(hex: 0xD45FA6)), // pink
        dynamic(light: Color(hex: 0x6A55CC), dark: Color(hex: 0x8C7AE6)), // violet
        dynamic(light: Color(hex: 0x7A6A00), dark: Color(hex: 0xB8A030)), // olive
    ]

    static let laneNames = ["Blue", "Green", "Amber", "Red", "Teal", "Pink", "Violet", "Olive"]
    /// Text colour that stays readable on a filled lane colour (light hues need dark text).
    static func onLane(_ index: Int) -> Color {
        let light: Set<Int> = [1, 2, 4, 7]
        return light.contains(((index % lanes.count) + lanes.count) % lanes.count) ? Color.black.opacity(0.85) : .white
    }

    static func lane(_ index: Int) -> Color { lanes[((index % lanes.count) + lanes.count) % lanes.count] }

    /// Colour in the graph: the checked-out branch's lane is the accent colour, every other lane
    /// keeps its hue but steps back, so the current branch is the one thing that stands out.
    static func lane(_ index: Int, head: Int?) -> Color {
        guard let head else { return lane(index) }
        return index == head ? Color.accentColor : lane(index).opacity(0.4)
    }

    /// Branch labels other than the checked-out one are neutral; a small dot carries the lane.
    static let badgeFill = dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.08))
    static let badgeStroke = dynamic(light: Color.black.opacity(0.13), dark: Color.white.opacity(0.14))

    // Status colours (GitHub Primer values), legible as text on both themes.
    static let added = dynamic(light: Color(hex: 0x1A7F37), dark: Color(hex: 0x3FB950))
    static let deleted = dynamic(light: Color(hex: 0xCF222E), dark: Color(hex: 0xF85149))
    static let modified = dynamic(light: Color(hex: 0x9A6700), dark: Color(hex: 0xD29922))
    static let renamed = dynamic(light: Color(hex: 0x0969DA), dark: Color(hex: 0x58A6FF))
    static let conflict = deleted

    static let rowHeight: CGFloat = 28
    /// Hairline between graph rows: visible enough to guide the eye, never a grid.
    static let rowDivider = dynamic(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.06))
    static let laneWidth: CGFloat = 16
    static let mono = Font.system(size: 12, design: .monospaced)

    static let separator = Color(nsColor: .separatorColor)
    /// Three surfaces so the layout reads at a glance: the content in the middle is the deepest
    /// (darkest in dark mode, white in light), the side panels sit one step out, the chrome one more.
    /// Content: the graph, diffs and the merge tool (also the fill of text fields).
    static let panel = dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x19191B))
    /// Side panels: branches/remotes on the left, commit or changes on the right.
    static let sidebar = dynamic(light: Color(hex: 0xF3F3F5), dark: Color(hex: 0x222225))
    static let window = Color(nsColor: .windowBackgroundColor)
    /// Tab bar and toolbar: opaque (materials there pick up the desktop colour).
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.155, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.935, alpha: 1)
    })
    /// The open tab: one step lighter than the chrome it sits on.
    static let tabActive = dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x3A3A3F))
    static let subtleFill = Color.primary.opacity(0.05)
    static let hoverFill = Color.primary.opacity(0.06)

    static func dynamic(light: Color, dark: Color) -> Color {
        let lightNS = NSColor(light), darkNS = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkNS : lightNS
        })
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension ChangeKind {
    var color: Color {
        switch self {
        case .added, .untracked: Theme.added
        case .deleted: Theme.deleted
        case .renamed, .copied: Theme.renamed
        case .conflicted: Theme.conflict
        case .modified, .typeChanged: Theme.modified
        }
    }

    var symbol: String {
        switch self {
        case .added, .untracked: "plus"
        case .deleted: "minus"
        case .renamed, .copied: "arrow.right"
        case .conflicted: "exclamationmark.triangle.fill"
        case .modified, .typeChanged: "pencil"
        }
    }
}

enum Formatters {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: Avatars

@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    /// Bounded and purged under memory pressure, unlike a dictionary.
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var missing: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func cached(_ email: String) -> NSImage? { images.object(forKey: email.lowercased() as NSString) }

    func load(_ email: String) async -> NSImage? {
        let key = email.lowercased()
        if let image = images.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if let task = inflight[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let url = Self.avatarURL(for: key) else { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image {
            // Store a 40×40 point (80 px) copy: avatars are drawn at ≤ 34 pt.
            let small = Self.downscaled(image, to: 80)
            images.setObject(small, forKey: key as NSString, cost: 80 * 80 * 4)
        } else {
            missing.insert(key)
        }
        return image
    }

    private static func downscaled(_ image: NSImage, to pixels: CGFloat) -> NSImage {
        guard image.size.width > pixels / 2 else { return image }
        let size = NSSize(width: pixels / 2, height: pixels / 2)
        let small = NSImage(size: size)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        return small
    }

    static func avatarURL(for email: String) -> URL? {
        // GitHub noreply addresses map straight to the GitHub avatar.
        if email.hasSuffix("@users.noreply.github.com") {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            if let plus = local.firstIndex(of: "+"), let id = Int(local[..<plus]) {
                return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=64")
            }
            guard let login = local.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { return nil }
            return URL(string: "https://github.com/\(login).png?size=64")
        }
        // SHA-256 rather than MD5: Gravatar accepts both, MD5 hashes of emails are trivially reversed.
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=64&d=404")
    }
}

struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 20
    var ring: Color? = nil

    @AppStorage("useGravatar") private var useGravatar = true
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Self.color(for: email.isEmpty ? name : email))
            Text(Self.initials(name))
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: max(1.5, size * 0.09)) }
        }
        .task(id: email) {
            guard useGravatar, !email.isEmpty else { image = nil; return }
            image = AvatarCache.shared.cached(email)
            if image == nil { image = await AvatarCache.shared.load(email) }
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    static func color(for key: String) -> Color {
        var hash: UInt32 = 5381
        for byte in key.lowercased().utf8 { hash = (hash &<< 5) &+ hash &+ UInt32(byte) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.45)   // white initials ≥ 4.5:1
    }
}

// MARK: Ref badge

struct RefBadgeView: View {
    let badge: RefBadge
    let color: Color
    var compact = false
    var untruncated = false

    var body: some View {
        let head = badge.isHead
        HStack(spacing: 5) {
            if badge.name.hasPrefix("-") {
                // Git refuses to create these; they only arrive from a remote, usually to trick tools.
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    .foregroundStyle(Theme.modified)
                    .help("This name starts with a dash, which is unusual and can be used to trick git tools. Dal handles it safely.")
            }
            if head {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
            } else if badge.tag != nil && badge.local == nil && badge.remotes.isEmpty {
                Image(systemName: "tag").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            if compact || untruncated {
                name
                if !compact { trailing }
            } else {
                // The name matters more than the location icons: drop the icons before truncating it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { name.fixedSize(); trailing }
                    name.fixedSize()
                    name
                }
            }
        }
        .font(.system(size: 12, weight: head ? .semibold : .medium))
        .foregroundStyle(head ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.leading, head ? 5 : 8)
        .padding(.trailing, 8)
        .frame(height: 23)
        .background(RoundedRectangle(cornerRadius: 6).fill(head ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.badgeFill)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(head ? Color.clear : Theme.badgeStroke, lineWidth: 1))
        .help(helpText)
    }

    private var name: some View {
        Text(badge.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: untruncated, vertical: false)
    }

    /// Where the branch lives (this Mac / a remote) and how far it is from its upstream.
    @ViewBuilder private var trailing: some View {
        let local = badge.local
        let ahead = local?.ahead ?? 0, behind = local?.behind ?? 0
        if local != nil || !badge.remotes.isEmpty || ahead > 0 || behind > 0 {
            HStack(spacing: 4) {
                if ahead > 0 { Text("↑\(ahead)") }
                if behind > 0 { Text("↓\(behind)") }
                if local != nil {
                    Image(systemName: "laptopcomputer").frame(width: 15)
                }
                if !badge.remotes.isEmpty {
                    Image(systemName: "icloud").frame(width: 15)
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(badge.isHead ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.leading, 2)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let local = badge.local {
            var line = "Local: \(local.name)"
            if let up = local.upstream {
                line += " → \(up)"
                if local.ahead > 0 { line += " ↑\(local.ahead)" }
                if local.behind > 0 { line += " ↓\(local.behind)" }
            }
            parts.append(line)
        }
        for remote in badge.remotes { parts.append("Remote: \(remote.name)") }
        if let tag = badge.tag { parts.append("Tag: \(tag.name)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: Toolbar button

struct ToolbarButton: View {
    let title: String
    let symbol: String
    var help: String? = nil
    var badge: Int = 0
    var compact = false
    /// While this button's command runs, a spinner takes the icon's place (same size, so nothing
    /// around it moves) and a click cancels instead.
    var loading = false
    var onCancel: (() -> Void)? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button {
            if loading { onCancel?() } else { action() }
        } label: {
            VStack(spacing: 3) {
                icon
                    .frame(width: 22, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 && !loading {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(x: 8, y: -6)
                        }
                    }
                if !compact { Text(title).font(.system(size: 11)) }
            }
            .frame(minWidth: compact ? 28 : 46, minHeight: compact ? 30 : nil)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? Theme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .onHover { hovering = $0 }
        .help(loading ? "Cancel \(title.lowercased())" : help ?? title)
        .accessibilityLabel(loading ? "Cancel \(title.lowercased())" : title)
    }

    @ViewBuilder private var icon: some View {
        if loading {
            if hovering && onCancel != nil {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
        }
    }
}

// MARK: Clicks

extension View {
    /// Hand cursor over clickable rows (macOS 15+ API; older systems keep the arrow).
    @ViewBuilder func pointingHandCursor() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }

    /// Single and double click on one gesture. Unlike stacking `onTapGesture(count: 2)` over
    /// `onTapGesture`, the single click fires immediately (no double-click delay) and the
    /// double click isn't swallowed by an inner tap handler.
    func onClick(_ single: @escaping () -> Void, double: (() -> Void)? = nil) -> some View {
        onTapGesture {
            if let double, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { double() } else { single() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { single() }
    }
}

// MARK: File rows

/// File status as a coloured glyph in a fixed 16pt column (no filled tile: the colour is the
/// signal, the chrome stays quiet).
struct ChangeIcon: View {
    let kind: ChangeKind
    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(kind.color)
            .frame(width: 16, height: 16)
            .help(kind.label)
    }
}

/// Small icon button with an on/off state shown as a neutral surface step, not an accent fill.
struct IconToggle: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.primary.opacity(0.12) : hovering ? Theme.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.primary : Theme.secondaryText)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A keyboard shortcut drawn as keycaps — Dal's one signature detail.
struct KeyCap: View {
    let keys: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.tokens(keys).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.10)).frame(height: 1).padding(.horizontal, 2)
                    }
            }
        }
        .accessibilityLabel(keys)
    }

    /// "⇧⌘O" → ["⇧", "⌘", "O"]; "esc" → ["esc"]; "↑↓" → ["↑", "↓"].
    static func tokens(_ keys: String) -> [String] {
        let symbols: Set<Character> = ["⌘", "⇧", "⌥", "⌃", "↑", "↓", "←", "→", "↩", "⌫", "⇥"]
        var result: [String] = []
        var word = ""
        for ch in keys {
            if symbols.contains(ch) || ch == " " {
                if !word.isEmpty { result.append(word); word = "" }
                if ch != " " { result.append(String(ch)) }
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }
}

struct FileRow: View {
    let change: FileChange
    var selected = false
    var actionTitle: String? = nil
    var actionSymbol: String? = nil
    var action: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var onSelect: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            ChangeIcon(kind: change.kind)
            HStack(spacing: 0) {
                Text(change.directory)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(0)
                Text(change.fileName)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 12))
            .help(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
            Spacer(minLength: 4)
            if let action, let actionTitle {
                Button(action: action) {
                    HStack(spacing: 3) {
                        if let actionSymbol { Image(systemName: actionSymbol).font(.system(size: 9, weight: .bold)) }
                        Text(actionTitle)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.10)))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel("\(actionTitle) \(change.fileName)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.22) : hovering ? Theme.hoverFill : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onClick(onSelect, double: onDoubleClick)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(change.kind.label): \(change.path)")
    }
}

struct SectionTitle: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.mutedText)
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.mutedText)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.mutedText).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Window dragging for the custom tab bar

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

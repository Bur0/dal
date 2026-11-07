import SwiftUI
import AppKit
import CryptoKit

// MARK: Theme

enum Theme {
    /// Lane colours: distinct hues tuned to read on both light and dark backgrounds.
    static let lanes: [Color] = [
        Color(hex: 0x2F9BE0), // blue
        Color(hex: 0x3DB46D), // green
        Color(hex: 0xE59A2F), // amber
        Color(hex: 0xE0534F), // red
        Color(hex: 0x1FB5B0), // teal
        Color(hex: 0xD45FA6), // pink
        Color(hex: 0x8C7AE6), // violet
        Color(hex: 0xB8A030), // olive
    ]

    static let laneNames = ["Blue", "Green", "Amber", "Red", "Teal", "Pink", "Violet", "Olive"]
    /// Text colour that stays readable on a filled lane colour (light hues need dark text).
    static func onLane(_ index: Int) -> Color {
        let light: Set<Int> = [1, 2, 4, 7]
        return light.contains(((index % lanes.count) + lanes.count) % lanes.count) ? Color.black.opacity(0.85) : .white
    }

    static func lane(_ index: Int) -> Color { lanes[((index % lanes.count) + lanes.count) % lanes.count] }

    static let added = Color(hex: 0x3DB46D)
    static let deleted = Color(hex: 0xE0534F)
    static let modified = Color(hex: 0xE59A2F)
    static let renamed = Color(hex: 0x2F9BE0)
    static let conflict = Color(hex: 0xE0534F)

    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 16
    static let mono = Font.system(size: 12, design: .monospaced)

    static let separator = Color(nsColor: .separatorColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let window = Color(nsColor: .windowBackgroundColor)
    /// Tab bar and toolbar: opaque (materials there pick up the desktop colour).
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.155, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.935, alpha: 1)
    })
    static let subtleFill = Color.primary.opacity(0.05)
    static let hoverFill = Color.primary.opacity(0.06)
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
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func cached(_ email: String) -> NSImage? { images[email.lowercased()] }

    func load(_ email: String) async -> NSImage? {
        let key = email.lowercased()
        if let image = images[key] { return image }
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
        if let image { images[key] = image } else { missing.insert(key) }
        return image
    }

    static func avatarURL(for email: String) -> URL? {
        // GitHub noreply addresses map straight to the GitHub avatar.
        if email.hasSuffix("@users.noreply.github.com") {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            if let plus = local.firstIndex(of: "+"), let id = Int(local[..<plus]) {
                return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=64")
            }
            return URL(string: "https://github.com/\(local).png?size=64")
        }
        let hash = Insecure.MD5.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
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
        return Color(hue: hue, saturation: 0.45, brightness: 0.62)
    }
}

// MARK: Ref badge

struct RefBadgeView: View {
    let badge: RefBadge
    let color: Color
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if badge.isHead {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            } else if badge.tag != nil {
                Image(systemName: "tag.fill").font(.system(size: 9))
            }
            Text(badge.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if !compact {
                if badge.local != nil {
                    Image(systemName: "laptopcomputer").font(.system(size: 9)).opacity(0.85)
                }
                if !badge.remotes.isEmpty {
                    Image(systemName: "cloud.fill").font(.system(size: 9)).opacity(0.85)
                }
            }
        }
        .font(.system(size: 11, weight: badge.isHead ? .semibold : .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(badge.isHead ? 0.38 : 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.75), lineWidth: 1))
        .help(helpText)
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
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(x: 10, y: -6)
                        }
                    }
                if !compact { Text(title).font(.system(size: 10.5)) }
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
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

// MARK: Clicks

extension View {
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

struct ChangeIcon: View {
    let kind: ChangeKind
    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(kind.color))
            .help(kind.label)
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
                    .foregroundStyle(.secondary)
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
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel("\(actionTitle) \(change.fileName)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
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
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Theme.subtleFill))
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
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
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

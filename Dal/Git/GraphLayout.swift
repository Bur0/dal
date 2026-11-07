import Foundation

/// A line segment drawn inside a single graph row.
/// - pass: a lane that continues straight through the row (top → bottom)
/// - toNode: a lane that ends at this row's node (top → node centre)
/// - fromNode: a lane that starts at this row's node (node centre → bottom)
struct GraphLine: Hashable {
    enum Kind: UInt8 { case pass, toNode, fromNode }
    let kind: Kind
    // Stored compactly (12 bytes instead of 32): a row keeps one line per lane passing through
    // it, so with hundreds of branches this dominates memory for long histories.
    private let fromLane: UInt16
    private let toLane: UInt16
    private let colorIndex: UInt32

    var from: Int { Int(fromLane) }
    var to: Int { Int(toLane) }
    var color: Int { Int(colorIndex) }

    init(kind: Kind, from: Int, to: Int, color: Int) {
        self.kind = kind
        self.fromLane = UInt16(clamping: from)
        self.toLane = UInt16(clamping: to)
        self.colorIndex = UInt32(clamping: color)
    }
}

struct GraphRow: Hashable {
    let lane: Int
    let color: Int
    let lines: [GraphLine]
}

/// Assigns commits to lanes, the same way `git log --graph` does, but keeps lanes in place
/// instead of collapsing them so lines stay straight while you scroll.
enum GraphLayout {
    struct Node {
        let id: String
        let parents: [String]
    }

    static func compute(_ nodes: [Node]) -> (rows: [GraphRow], width: Int) {
        var lanes: [String?] = []
        var colors: [Int] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(nodes.count)
        var width = 1

        for node in nodes {
            let top = lanes
            let topColors = colors
            var lines: [GraphLine] = []

            let idx: Int
            if let i = top.firstIndex(where: { $0 == node.id }) {
                idx = i
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                idx = free
                colors[free] = nextColor
                nextColor += 1
            } else {
                idx = lanes.count
                lanes.append(nil)
                colors.append(nextColor)
                nextColor += 1
            }

            for (i, value) in top.enumerated() {
                guard let value else { continue }
                if value == node.id {
                    lines.append(GraphLine(kind: .toNode, from: i, to: idx, color: topColors[i]))
                    if i != idx { lanes[i] = nil }
                } else {
                    lines.append(GraphLine(kind: .pass, from: i, to: i, color: topColors[i]))
                }
            }

            let nodeColor = colors[idx]
            if let first = node.parents.first {
                lanes[idx] = first
                lines.append(GraphLine(kind: .fromNode, from: idx, to: idx, color: nodeColor))
                for parent in node.parents.dropFirst() {
                    if let j = lanes.firstIndex(where: { $0 == parent }) {
                        if j != idx {
                            lines.append(GraphLine(kind: .fromNode, from: idx, to: j, color: colors[j]))
                        }
                    } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                        lanes[free] = parent
                        colors[free] = nextColor
                        nextColor += 1
                        lines.append(GraphLine(kind: .fromNode, from: idx, to: free, color: colors[free]))
                    } else {
                        lanes.append(parent)
                        colors.append(nextColor)
                        nextColor += 1
                        lines.append(GraphLine(kind: .fromNode, from: idx, to: lanes.count - 1, color: nextColor - 1))
                    }
                }
            } else {
                lanes[idx] = nil
            }

            // Compact: close gaps left by lanes that ended here so the graph stays narrow.
            // Lanes to the right of a gap slide left on their way to the next row.
            if lanes.contains(where: { $0 == nil }) {
                var map: [Int: Int] = [:]
                var newLanes: [String?] = []
                var newColors: [Int] = []
                for (i, value) in lanes.enumerated() where value != nil {
                    map[i] = newLanes.count
                    newLanes.append(value)
                    newColors.append(colors[i])
                }
                lines = lines.map { line in
                    switch line.kind {
                    case .pass, .fromNode:
                        return GraphLine(kind: line.kind, from: line.from, to: map[line.to] ?? line.to, color: line.color)
                    case .toNode:
                        return line
                    }
                }
                lanes = newLanes
                colors = newColors
            }
            width = max(width, top.count, lanes.count, idx + 1)
            rows.append(GraphRow(lane: idx, color: nodeColor, lines: lines))
        }
        return (rows, width)
    }
}

import CoreGraphics
import Foundation

struct KeySpec: Identifiable, Sendable {
    let id: String
    let label: String
    var widthUnits: CGFloat = 1
    var systemImage: String?
    var isLetter: Bool { id.hasPrefix("char_") && label.allSatisfy(\.isLetter) }
    static func char(_ text: String) -> KeySpec { KeySpec(id: "char_\(text)", label: text) }
}

struct KeyboardLayout: Sendable {
    var symbols = false
    var fullSizeKeys = false
    var compact = false
    var rows: [[KeySpec]] {
        let delete = KeySpec(id: "delete", label: "Delete", widthUnits: 1.4, systemImage: "delete.left")
        let caps = KeySpec(id: "caps", label: "Caps", widthUnits: 1.4, systemImage: "shift")
        let main: [[KeySpec]] = symbols ? [
            Array("1234567890").map { .char(String($0)) } + [delete],
            [caps] + Array("@#$%&*()¿?").map { .char(String($0)) },
            Array("¡!€+=/\\:;\"'").map { .char(String($0)) },
        ] : [
            Array("QWERTYUIOP").map { .char(String($0)) } + [delete],
            [caps] + Array("ASDFGHJKLÑ").map { .char(String($0)) },
            Array("ZXCVBNM,.'-").map { .char(String($0)) },
        ]
        return main + [[KeySpec(id: "symbols", label: symbols ? "ABC" : "123", widthUnits: 1.5),
                        KeySpec(id: "space", label: "Space", widthUnits: 6),
                        KeySpec(id: "done", label: "Return", widthUnits: 1.8, systemImage: "return")]]
    }
    var keys: [KeySpec] { rows.flatMap { $0 } }

    func panelFrame(in size: CGSize) -> CGRect {
        if compact {
            let width = min(1180, max(0, size.width - 32))
            let height = min(348, max(0, size.height - 96))
            return CGRect(x: (size.width - width) / 2, y: size.height - height - 16, width: width, height: height)
        }
        let width = min(1180, max(0, size.width - 48))
        let height = min(348, max(0, fullSizeKeys ? size.height - 208 : size.height * 0.49))
        return CGRect(x: (size.width - width) / 2, y: size.height - height - 28, width: width, height: height)
    }

    /// Rendering, hit testing and swipe templates all consume these exact frames.
    func keyFrames(in size: CGSize) -> [String: CGRect] {
        let content = panelFrame(in: size).insetBy(dx: 16, dy: 16)
        let spacing: CGFloat = 10
        let height = (content.height - 3 * spacing) / 4
        var result: [String: CGRect] = [:]
        for (index, row) in rows.enumerated() {
            let inset: CGFloat = index == 2 ? 32 : (index == 3 ? 100 : 0)
            let totalUnits = row.reduce(0) { $0 + $1.widthUnits }
            let unit = (content.width - 2 * inset - CGFloat(row.count - 1) * spacing) / totalUnits
            var x = content.minX + inset
            for key in row {
                result[key.id] = CGRect(x: x, y: content.minY + CGFloat(index) * (height + spacing),
                                        width: key.widthUnits * unit, height: height)
                x += key.widthUnits * unit + spacing
            }
        }
        return result
    }

    func suggestionFrames(in size: CGSize, count: Int) -> [CGRect] {
        let count = min(4, max(0, count))
        guard count > 0 else { return [] }
        let panel = panelFrame(in: size)
        let width = (panel.width - 32 - (compact ? 176 : 0) - CGFloat(count - 1) * 10) / CGFloat(count)
        return (0..<count).map { CGRect(x: panel.minX + 16 + CGFloat($0) * (width + 10),
                                        y: panel.minY - 64, width: width, height: 48) }
    }

    func dragHandleFrame(in size: CGSize) -> CGRect? {
        compact ? CGRect(x: size.width - 160, y: 16, width: 112, height: 48) : nil
    }

    /// The handle attracts nearby pinches without stealing a direct key or word.
    func hitsDragHandle(_ point: CGPoint, in size: CGSize, suggestionCount: Int) -> Bool {
        guard let handle = dragHandleFrame(in: size), handle.insetBy(dx: -48, dy: -28).contains(point) else { return false }
        if keyFrames(in: size).values.contains(where: { $0.contains(point) }) { return false }
        if suggestionFrames(in: size, count: suggestionCount).contains(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) { return false }
        return true
    }

    func hitKey(at point: CGPoint, in size: CGSize, previous: String? = nil) -> String? {
        let frames = keyFrames(in: size)
        // Small, bounded hysteresis avoids flickering between adjacent keys.
        if let previous, let frame = frames[previous], frame.insetBy(dx: -3, dy: -3).contains(point) {
            return previous
        }
        if let direct = keys.first(where: { frames[$0.id]?.contains(point) == true }) { return direct.id }
        // Wide attraction zones make frequent controls easy to acquire in mid-air.
        // Direct letter hits always win, even where a control's gravity overlaps them.
        let gravity: [(String, CGFloat, CGFloat)] = [("space", 56, 40), ("delete", 38, 28)]
        let attracted = gravity.compactMap { id, dx, dy -> (String, CGFloat)? in
            guard let rect = frames[id], rect.insetBy(dx: -dx, dy: -dy).contains(point) else { return nil }
            let outsideX = max(rect.minX - point.x, point.x - rect.maxX, 0)
            let outsideY = max(rect.minY - point.y, point.y - rect.maxY, 0)
            return (id, hypot(outsideX / dx, outsideY / dy))
        }.min { $0.1 < $1.1 }
        if let attracted { return attracted.0 }
        return keys.compactMap { key -> (String, CGFloat)? in
            guard let frame = frames[key.id], frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
            let score = hypot((point.x - frame.midX) / frame.width, (point.y - frame.midY) / frame.height)
            return (key.id, score)
        }.min { $0.1 < $1.1 }?.0
    }

    func letterCenters(in size: CGSize) -> [Character: CGPoint] {
        let frames = keyFrames(in: size)
        return Dictionary(uniqueKeysWithValues: keys.filter(\.isLetter).compactMap { key in
            guard let letter = key.label.lowercased().first, let frame = frames[key.id] else { return nil }
            return (letter, CGPoint(x: frame.midX, y: frame.midY))
        })
    }
}

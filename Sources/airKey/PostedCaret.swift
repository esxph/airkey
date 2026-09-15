import Foundation

struct TextSelection: Equatable {
    let location: Int
    let length: Int
    init(_ range: CFRange) { location = range.location; length = range.length }
    init(location: Int, length: Int = 0) { self.location = location; self.length = length }
}

/// Posted keyboard events and the destination's AX caret update asynchronously.
/// Accept only recently posted intermediate positions, within this same field;
/// never let a slow caret report erase the word being typed on every fast press.
struct PostedCaret {
    private(set) var expected: TextSelection?
    private var pending: [TextSelection] = []
    private var sentAt: TimeInterval = -.infinity

    mutating func reset(to selection: TextSelection?) {
        expected = selection; pending.removeAll(); sentAt = -.infinity
    }
    mutating func posted(_ selection: TextSelection, at time: TimeInterval) {
        if time - sentAt > 0.20 { pending.removeAll() }
        if let expected { pending.append(expected) }
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        expected = selection; sentAt = time
    }
    mutating func accepts(_ actual: TextSelection, at time: TimeInterval) -> Bool {
        if actual == expected { pending.removeAll(); return true }
        return time - sentAt <= 0.20 && pending.contains(actual)
    }
}

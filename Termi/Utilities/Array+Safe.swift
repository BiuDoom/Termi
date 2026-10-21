/// Safe array subscript — returns `nil` instead of crashing on out-of-bounds.
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

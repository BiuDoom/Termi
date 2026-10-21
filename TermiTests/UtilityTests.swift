import Testing
import Foundation
@testable import Termi

// MARK: - Array+Safe

@Test func arraySafeValidIndex() {
    let arr = ["a", "b", "c"]
    #expect(arr[safe: 0] == "a")
    #expect(arr[safe: 1] == "b")
    #expect(arr[safe: 2] == "c")
}

@Test func arraySafeOutOfBounds() {
    let arr = ["a", "b", "c"]
    #expect(arr[safe: 3] == nil)
    #expect(arr[safe: 100] == nil)
}

@Test func arraySafeNegativeIndex() {
    let arr = ["a", "b", "c"]
    #expect(arr[safe: -1] == nil)
    #expect(arr[safe: -100] == nil)
}

@Test func arraySafeEmptyArray() {
    let arr: [Int] = []
    #expect(arr[safe: 0] == nil)
}

@Test func arraySafeSingleElement() {
    let arr = [42]
    #expect(arr[safe: 0] == 42)
    #expect(arr[safe: 1] == nil)
}

// MARK: - TimestampFormatter

@Test func timestampFormatterNowReturnsISO8601() {
    let timestamp = TimestampFormatter.now()
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: timestamp)
    #expect(date != nil, "TimestampFormatter.now() should return parseable ISO8601")
}

@Test func timestampFormatterNowIsRecent() {
    let timestamp = TimestampFormatter.now()
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: timestamp) else {
        Issue.record("Failed to parse timestamp")
        return
    }
    let elapsed = abs(date.timeIntervalSinceNow)
    #expect(elapsed < 5, "Timestamp should be within 5 seconds of now")
}

@Test func timestampFormatterConsecutiveCallsIncrease() {
    let t1 = TimestampFormatter.now()
    let t2 = TimestampFormatter.now()
    // String comparison works for ISO8601 timestamps
    #expect(t1 <= t2)
}

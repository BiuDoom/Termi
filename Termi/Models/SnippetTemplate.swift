import Foundation

/// `{{variable}}` placeholders in snippets, filled in right before the snippet runs.
enum SnippetTemplate {
    /// Unique placeholder names in order of first appearance.
    static func placeholders(in command: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in matches(in: command).map(\.name) where seen.insert(name).inserted {
            names.append(name)
        }
        return names
    }

    /// Replace every `{{name}}` with its value (missing values become empty strings).
    static func render(_ command: String, values: [String: String]) -> String {
        var result = command
        for match in matches(in: command).reversed() {
            result.replaceSubrange(match.range, with: values[match.name] ?? "")
        }
        return result
    }

    /// The placeholders that still have no value: a command rendered with them would run with
    /// holes in it ("tail -f " instead of "tail -f /var/log/syslog").
    static func missingValues(in command: String, values: [String: String]) -> [String] {
        placeholders(in: command).filter { (values[$0] ?? "").isEmpty }
    }

    private static func matches(in command: String) -> [(name: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.\- ]+?)\s*\}\}"#) else { return [] }
        let nsRange = NSRange(command.startIndex..., in: command)
        return regex.matches(in: command, range: nsRange).compactMap { match in
            guard let whole = Range(match.range, in: command),
                  let nameRange = Range(match.range(at: 1), in: command) else { return nil }
            return (String(command[nameRange]), whole)
        }
    }
}

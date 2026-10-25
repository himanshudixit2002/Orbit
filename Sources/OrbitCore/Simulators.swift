import Foundation

/// The simulator systems Xcode keeps, read from `xcrun simctl runtime list`.
public enum SimulatorRuntimes {
    /// "iOS 26.1" (and others) and the total size, e.g. from "Total Disk Images: 1 (7.8G)".
    public static func parse(_ text: String) -> (detail: String, size: Int64)? {
        let names = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let paren = trimmed.range(of: " ("), trimmed.contains(" - "),
                  ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"].contains(where: trimmed.hasPrefix) else { return nil }
            return String(trimmed[..<paren.lowerBound])
        }
        guard !names.isEmpty, let total = text.range(of: "Total Disk Images:") else { return nil }
        let rest = text[total.upperBound...]
        guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close else { return nil }
        let amount = rest[rest.index(after: open)..<close]
        let units: [Character: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        guard let unit = amount.last, let factor = units[unit], let number = Double(amount.dropLast()) else { return nil }
        return (names.joined(separator: ", "), Int64(number * factor))
    }
}

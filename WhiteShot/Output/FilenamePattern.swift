import Foundation

/// Expands filename templates such as `${title} ${YYYY}-${MM}-${DD}`, using the variable names
/// Greenshot users already know. Variable names are case sensitive: `${MM}` is the month, `${mm}` the minute.
enum FilenamePattern {
    struct Context {
        var date = Date()
        var title = ""
        var number = 1
    }

    static let variables: [(name: String, help: String)] = [
        ("YYYY", String(localized: "Year, four digits")),
        ("YY", String(localized: "Year, two digits")),
        ("MM", String(localized: "Month, two digits")),
        ("DD", String(localized: "Day, two digits")),
        ("hh", String(localized: "Hour (24h), two digits")),
        ("mm", String(localized: "Minute, two digits")),
        ("ss", String(localized: "Second, two digits")),
        ("ms", String(localized: "Millisecond, three digits")),
        ("NUM", String(localized: "Running number, six digits")),
        ("title", String(localized: "Window title of the captured window")),
        ("hostname", String(localized: "Name of this Mac")),
        ("username", String(localized: "Your user name")),
    ]

    static func expand(_ pattern: String, context: Context) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: context.date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let values: [String: String] = [
            "YYYY": String(format: "%04d", c.year ?? 0),
            "YY": two((c.year ?? 0) % 100),
            "MM": two(c.month),
            "DD": two(c.day),
            "hh": two(c.hour),
            "mm": two(c.minute),
            "ss": two(c.second),
            // Rounded, because a Date is a Double and 7 ms can read back as 6.9999 ms. Capped at 999 so it
            // never disagrees with the (truncated) seconds field.
            "ms": String(format: "%03d", min(999, Int((Double(c.nanosecond ?? 0) / 1_000_000).rounded()))),
            "NUM": String(format: "%06d", context.number),
            "title": context.title,
            "hostname": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "username": NSUserName(),
        ]
        var result = pattern
        for (name, value) in values { result = result.replacingOccurrences(of: "${\(name)}", with: value) }
        return result
    }

    /// Makes one path component safe: no separators or control characters, no leading dot, bounded length.
    static func sanitize(component: String) -> String {
        var cleaned = component.unicodeScalars.map { scalar -> Character in
            if scalar == ":" || scalar == "/" || scalar == "\\" || scalar.value < 32 { return "-" }
            return Character(scalar)
        }.map(String.init).joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned
    }

    /// Expands the pattern into a relative path. A `/` in the pattern makes subfolders, like in Greenshot.
    static func relativePath(pattern: String, context: Context) -> [String] {
        let expanded = expand(pattern, context: context)
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(component: String($0)) }
            .filter { !$0.isEmpty && $0 != ".." }
        return parts.isEmpty ? ["WhiteShot"] : parts
    }

    /// A URL inside `directory` that does not exist yet; appends " 2", " 3", ... instead of overwriting.
    static func uniqueURL(in directory: URL, components: [String], fileExtension: String, fileManager: FileManager = .default) -> URL {
        var folder = directory
        for part in components.dropLast() { folder.appendPathComponent(part, isDirectory: true) }
        let name = components.last ?? "WhiteShot"
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }
}

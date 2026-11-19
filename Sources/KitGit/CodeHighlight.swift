import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

struct InlineChange {
    let old: Set<Int>
    let new: Set<Int>

    init(old: String, new: String) {
        let before = Array(old)
        let after = Array(new)
        let prefix = zip(before, after).prefix { $0 == $1 }.count
        let suffix = zip(before.dropFirst(prefix).reversed(), after.dropFirst(prefix).reversed())
            .prefix { $0 == $1 }.count
        let oldMiddle = before[prefix..<(before.count - suffix)]
        let newMiddle = after[prefix..<(after.count - suffix)]
        // shortcut: highlight the changed middle of very long lines until a bounded granular diff is needed.
        guard max(oldMiddle.count, newMiddle.count) <= 800 else {
            self.old = Set(oldMiddle.indices)
            self.new = Set(newMiddle.indices)
            return
        }
        let differences = newMiddle.difference(from: oldMiddle)
        var removed: Set<Int> = []
        var added: Set<Int> = []
        for change in differences {
            switch change {
            case .remove(let offset, _, _): removed.insert(prefix + offset)
            case .insert(let offset, _, _): added.insert(prefix + offset)
            }
        }
        self.old = removed
        self.new = added
    }
}

struct CodeHighlight {
    private enum Kind: Int {
        case comment = 1, string, keyword, number, annotation

        #if canImport(SwiftUI)
        var color: Color {
            switch self {
            case .comment: Color(red: 0.56, green: 0.65, blue: 0.70)
            case .string: Color(red: 0.66, green: 0.84, blue: 0.58)
            case .keyword: Color(red: 0.81, green: 0.66, blue: 1)
            case .number: Color(red: 1, green: 0.75, blue: 0.49)
            case .annotation: Color(red: 0.47, green: 0.79, blue: 0.94)
            }
        }
        #endif
    }

    private let matcher: NSRegularExpression?

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let comment: String
        var keywords = "true|false|null|nil|None"
        switch ext {
        case "swift", "c", "cpp", "cxx", "cc", "h", "hpp", "m", "java", "kt", "kts", "rs", "go", "cs", "js", "jsx", "ts", "tsx", "mjs", "cjs", "css", "scss":
            comment = #"//.*|/\*.*?\*/"#
            keywords += "|let|var|const|func|fn|def|function|class|struct|enum|interface|trait|protocol|type|extension|import|export|package|use|pub|public|private|internal|protected|static|final|mut|self|super|this|new|return|throw|throws|try|catch|except|await|async|if|else|elseif|guard|switch|case|default|break|continue|for|while|do|in|of|match|where|yield|void|int|bool|double|string|undefined"
        case "py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "ini", "conf", "env", "r":
            comment = #"#.*"#
            keywords += "|def|class|end|module|from|import|as|global|return|raise|try|except|finally|with|await|async|lambda|if|elif|else|fi|then|for|while|do|done|in|not|and|or|is|pass|break|continue|case|esac|export|local|True|False"
        case "json", "jsonc":
            comment = #"//.*|/\*.*?\*/"#
        case "html", "htm", "xml", "svg", "plist":
            comment = #"<!--.*?-->"#
        case "sql", "lua":
            comment = #"--.*"#
            keywords += "|select|from|join|where|insert|update|delete|create|table|group|by|order|as|limit|function|end|local|then|return"
        default:
            matcher = nil
            return
        }
        let expression = #"("# + comment + #")|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(\b(?:"# +
            keywords + #")\b)|(\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b)|(@[\w]+|</?[\w:-]+|\b[\w-]+(?=\s*[:=]))"#
        matcher = try? NSRegularExpression(pattern: expression, options: ext == "sql" ? [.caseInsensitive] : [])
    }

    private func matches(in source: String) -> [(NSRange, Kind)] {
        matcher?.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).compactMap { match in
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                if let kind = Kind(rawValue: group) { return (match.range(at: group), kind) }
            }
            return nil
        } ?? []
    }

    #if !os(macOS)
    func tokens(in source: String) -> [[Int]] {
        matches(in: source).map { range, kind in [range.location, range.length, kind.rawValue] }
    }
    #endif

    #if canImport(SwiftUI)
    func style(_ source: String, changed: Set<Int> = [], background: Color? = nil,
               foreground: Color? = nil, prefix: String = "") -> AttributedString {
        let matches = matches(in: source)
        var result = AttributedString(prefix)
        result.foregroundColor = foreground
        var segment = ""
        var previousKind: Kind?
        var previousChange = false
        var search = 0
        var utf16Offset = 0
        func flush() {
            guard !segment.isEmpty else { return }
            var part = AttributedString(segment)
            part.foregroundColor = previousKind?.color ?? foreground
            if previousChange { part.backgroundColor = background }
            result += part
            segment = ""
        }
        for (index, char) in source.enumerated() {
            while search < matches.count && NSMaxRange(matches[search].0) <= utf16Offset { search += 1 }
            let kind = search < matches.count && NSLocationInRange(utf16Offset, matches[search].0)
                ? matches[search].1 : nil
            let highlighted = changed.contains(index)
            if kind != previousKind || highlighted != previousChange { flush() }
            previousKind = kind
            previousChange = highlighted
            if char == "\t" { segment += "    " }
            else if char != "\r" { segment.append(char) }
            utf16Offset += String(char).utf16.count
        }
        flush()
        return result
    }
    #endif
}

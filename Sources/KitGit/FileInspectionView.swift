import SwiftUI

struct FileInspectionView: View {
    private enum Mode: String, CaseIterable {
        case diff = "Diff", before = "Before", after = "After"
    }

    let inspection: FileInspection
    let canStage: Bool
    private let highlighter: CodeHighlight
    @Binding var selection: Set<Int>
    @State private var mode = Mode.diff
    @AppStorage("sideBySideDiff") private var split = false

    init(path: String, inspection: FileInspection, canStage: Bool, selection: Binding<Set<Int>>) {
        highlighter = CodeHighlight(path: path)
        self.inspection = inspection
        self.canStage = canStage
        _selection = selection
        _mode = State(initialValue: inspection.patch.raw.isEmpty ? .after : .diff)
    }

    private let paper = Color(red: 0.107, green: 0.118, blue: 0.136)
    private let green = Color(red: 0.45, green: 0.85, blue: 0.67)
    private let red = Color(red: 1, green: 0.57, blue: 0.59)
    private let rule = Color.white.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("File view", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if mode == .diff && !inspection.hunks.isEmpty {
                    Picker("Diff layout", selection: $split) {
                        Text("Unified").tag(false)
                        Text("Split").tag(true)
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                if mode != .diff {
                    Text(mode == .before ? inspection.beforeTitle : inspection.afterTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(7)
            Divider()
            switch mode {
            case .before: preview(inspection.before)
            case .after: preview(inspection.after)
            case .diff:
                if inspection.hunks.isEmpty {
                    if case .binary = inspection.before {
                        imageDiff
                    } else if case .binary = inspection.after {
                        imageDiff
                    } else {
                        message(binaryMetadata)
                    }
                } else {
                    if split {
                        HStack {
                            Text(inspection.beforeTitle).frame(maxWidth: .infinity, alignment: .leading)
                            Text(inspection.afterTitle).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(7)
                        Divider()
                    }
                    diffRows.id(split)
                }
            }
        }
        .background(paper)
    }

    private var binaryMetadata: String {
        let details = inspection.patch.header.filter {
            $0.hasPrefix("old mode ") || $0.hasPrefix("new mode ") || $0.hasPrefix("Submodule ")
        }
        return details.isEmpty ? "No textual changes" : details.joined(separator: "\n")
    }

    private var imageDiff: some View {
        HStack(spacing: 0) {
            VStack {
                Text(inspection.beforeTitle).font(.caption.weight(.semibold)).padding(6)
                preview(inspection.before)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack {
                Text(inspection.afterTitle).font(.caption.weight(.semibold)).padding(6)
                preview(inspection.after)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func preview(_ snapshot: FileSnapshot) -> some View {
        switch snapshot {
        case .absent: message("This file does not exist in this version")
        case .tooLarge: message("This file exceeds the 12 MB preview limit")
        case .unavailable: message("A preview is unavailable for this file")
        case .binary(let data):
            if let image = NSImage(data: data), image.isValid {
                Image(nsImage: image).resizable().scaledToFit()
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("File image")
            } else {
                message("Binary file · " + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
            }
        case .text(let text):
            if text.isEmpty {
                message("Empty file")
            } else {
                let lines = text.droppingFinalNewline.components(separatedBy: "\n")
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                number(index + 1)
                                Text(highlighter.style(lines[index])).textSelection(.enabled).fixedSize()
                            }.frame(minHeight: 18).padding(.trailing, 10)
                        }
                    }.padding(.vertical, 5).font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diffRows: some View {
        GeometryReader { geometry in
            let longest = inspection.hunks.lazy.flatMap(\.lines).map { $0.source.text.utf16.count }.max() ?? 0
            let viewport = split ? geometry.size.width / 2 : geometry.size.width
            let width = split ? viewport : max(viewport, CGFloat(min(longest, 4000)) * 8 + 109)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(inspection.hunks) { hunk in
                        HStack {
                            Text(hunk.header).foregroundStyle(.tint)
                            if canStage {
                                Button("Select Hunk") {
                                    selection.formUnion(hunk.lines.filter { $0.source.selectable }.map(\.id))
                                }.buttonStyle(.borderless)
                            }
                        }.padding(6).frame(width: split ? width * 2 : width, alignment: .leading)
                            .background(rule)
                        if split {
                            ForEach(hunk.pairs) { pair in
                                HStack(alignment: .top, spacing: 0) {
                                    cell(pair.left, side: false, width: width, changes: hunk.changes)
                                        .overlay(alignment: .trailing) { rule.frame(width: 1) }
                                    cell(pair.right, side: true, width: width, changes: hunk.changes)
                                }
                            }
                        } else {
                            ForEach(hunk.lines) { line in
                                cell(line, side: nil, width: width, changes: hunk.changes)
                            }
                        }
                    }
                }.font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func cell(_ line: FileInspection.NumberedHunk.Line?, side: Bool?, width: CGFloat,
                      changes: [Int: Set<Int>]) -> some View {
        let source = line?.source
        let sign = source?.text.first
        let foreground = sign == "+" ? green : sign == "-" ? red : Color.primary
        let selected = source.map { selection.contains($0.id) } == true
        return HStack(alignment: .top, spacing: 4) {
            if side != true { number(line?.old) }
            if side != false { number(line?.new) }
            if canStage {
                if let source, source.selectable {
                    Toggle("Select \(source.text)", isOn: Binding(get: {
                        selection.contains(source.id)
                    }, set: { enabled in
                        if enabled { selection.insert(source.id) }
                        else { selection.remove(source.id) }
                    })).toggleStyle(.checkbox).labelsHidden().frame(width: 17)
                } else {
                    Color.clear.frame(width: 17, height: 1)
                }
            }
            if let source {
                let marker = sign == "\\"
                let content = marker ? source.text : String(source.text.dropFirst())
                let prefix = side == nil && !marker ? String(source.text.prefix(1)) : ""
                Text(highlighter.style(content, changed: changes[source.id] ?? [],
                                       background: foreground.opacity(0.40), foreground: foreground, prefix: prefix))
                    .textSelection(.enabled)
                    .lineLimit(side == nil ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.trailing, 8).padding(.vertical, 2)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 19, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.23) :
                        source?.selectable == true ? foreground.opacity(0.12) : .clear)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .monospacedDigit().foregroundStyle(.secondary)
            .frame(width: 32, alignment: .trailing)
            .accessibilityHidden(true)
    }


}

struct RepositoryFilesView: View {
    let paths: [String]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter files by path", text: $query).textFieldStyle(.roundedBorder)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
            Divider()
            let matching = query.isEmpty ? paths : paths.filter { $0.localizedCaseInsensitiveContains(query) }
            if matching.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass")
            } else {
                List(matching, id: \.self) { path in
                    Button { open(path) } label: {
                        Label(path, systemImage: "doc")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.frame(width: 580, height: 460)
    }
}

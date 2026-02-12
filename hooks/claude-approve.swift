import AppKit
import Foundation

// MARK: - Read hook input from stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
let toolName  = input["tool_name"] as? String ?? "Tool"
let toolInput = input["tool_input"] as? [String: Any] ?? [:]
let cwd       = input["cwd"] as? String ?? ""
let sessionId = input["session_id"] as? String ?? ""

let sessionName = (cwd as NSString).lastPathComponent
let sessionFull = "\(sessionName)  —  \(cwd)"

// --- Session auto-approve check ---
let sessionFile = "/tmp/claude-hook-sessions/\(sessionId)"
if let contents = try? String(contentsOfFile: sessionFile, encoding: .utf8),
   contents.components(separatedBy: "\n").contains(toolName) {
    let auto: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved (\(toolName) allowed for session)"
    ]]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: auto))
    exit(0)
}

// MARK: - App

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSSound(named: "Funk")?.play()

// MARK: - Colors

let bgColor   = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
let codeBg    = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1.0)
let borderClr = NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.26, alpha: 1.0)
let textPri   = NSColor(calibratedWhite: 0.93, alpha: 1.0)
let textSec   = NSColor(calibratedWhite: 0.55, alpha: 1.0)
let codeTxt   = NSColor(calibratedRed: 0.78, green: 0.85, blue: 0.78, alpha: 1.0)
let rmColor   = NSColor(calibratedRed: 1.0,  green: 0.55, blue: 0.55, alpha: 1.0)
let rmBg      = NSColor(calibratedRed: 0.35, green: 0.10, blue: 0.10, alpha: 1.0)
let addColor  = NSColor(calibratedRed: 0.55, green: 1.0,  blue: 0.65, alpha: 1.0)
let addBgC    = NSColor(calibratedRed: 0.08, green: 0.25, blue: 0.12, alpha: 1.0)
let fileClr   = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1.0)
let lblClr    = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.70, alpha: 1.0)

let mono     = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
let lblFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

// MARK: - Gist (one-line summary)

func buildGist() -> String {
    switch toolName {
    case "Bash":
        let cmd = toolInput["command"] as? String ?? ""
        let first = cmd.components(separatedBy: "\n").first ?? cmd
        let short = first.count > 80 ? String(first.prefix(77)) + "..." : first
        return "Run: \(short)"
    case "Edit":
        let f = (toolInput["file_path"] as? String ?? "") as NSString
        return "Edit \(f.lastPathComponent)"
    case "Write":
        let f = (toolInput["file_path"] as? String ?? "") as NSString
        return "Write \(f.lastPathComponent)"
    case "Read":
        let f = (toolInput["file_path"] as? String ?? "") as NSString
        return "Read \(f.lastPathComponent)"
    case "NotebookEdit":
        let f = (toolInput["notebook_path"] as? String ?? "") as NSString
        let m = toolInput["edit_mode"] as? String ?? "edit"
        return "\(m.capitalized) cell in \(f.lastPathComponent)"
    case "Task":
        return toolInput["description"] as? String ?? "Launch agent"
    case "WebFetch":
        let u = toolInput["url"] as? String ?? ""
        return "Fetch \(u.count > 60 ? String(u.prefix(57)) + "..." : u)"
    case "WebSearch":
        return "Search: \(toolInput["query"] as? String ?? "")"
    case "Glob":
        return "Find files: \(toolInput["pattern"] as? String ?? "")"
    case "Grep":
        return "Search code: \(toolInput["pattern"] as? String ?? "")"
    default:
        return "\(toolName)"
    }
}

// MARK: - Render tool_input

// MARK: - ANSI → NSAttributedString (for zsh syntax highlighting)

func parseAnsi(_ raw: String, defaultColor: NSColor = codeTxt) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var cur = defaultColor
    let parts = raw.components(separatedBy: "\u{1b}[")
    for (i, part) in parts.enumerated() {
        if i == 0 { result.append(NSAttributedString(string: part, attributes: [.font: mono, .foregroundColor: cur])); continue }
        guard let mIdx = part.firstIndex(of: "m") else {
            result.append(NSAttributedString(string: part, attributes: [.font: mono, .foregroundColor: cur])); continue
        }
        let code = String(part[part.startIndex..<mIdx])
        let text = String(part[part.index(after: mIdx)...])
        let codes = code.components(separatedBy: ";").compactMap { Int($0) }
        for c in codes {
            switch c {
            case 0:  cur = defaultColor
            case 30: cur = NSColor(calibratedWhite: 0.35, alpha: 1)
            case 31: cur = NSColor(calibratedRed: 1.0, green: 0.40, blue: 0.40, alpha: 1)
            case 32: cur = NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.50, alpha: 1)
            case 33: cur = NSColor(calibratedRed: 0.90, green: 0.80, blue: 0.35, alpha: 1)
            case 34: cur = NSColor(calibratedRed: 0.40, green: 0.60, blue: 1.0, alpha: 1)
            case 35: cur = NSColor(calibratedRed: 0.75, green: 0.50, blue: 0.95, alpha: 1)
            case 36: cur = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.90, alpha: 1)
            case 37: cur = NSColor(calibratedWhite: 0.90, alpha: 1)
            case 39: cur = defaultColor
            case 90: cur = NSColor(calibratedWhite: 0.55, alpha: 1)
            case 91: cur = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.55, alpha: 1)
            case 92: cur = NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.60, alpha: 1)
            case 93: cur = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.55, alpha: 1)
            case 94: cur = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)
            case 95: cur = NSColor(calibratedRed: 0.90, green: 0.60, blue: 1.0, alpha: 1)
            case 96: cur = NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0, alpha: 1)
            case 97: cur = NSColor(calibratedWhite: 1.0, alpha: 1)
            default: break
            }
        }
        if !text.isEmpty { result.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: cur])) }
    }
    return result
}

func highlightBash(_ cmd: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let shKeyword = NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.90, alpha: 1)
    let shString  = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
    let shFlag    = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)
    let shPipe    = NSColor(calibratedRed: 0.90, green: 0.75, blue: 0.40, alpha: 1)
    let shComment = NSColor(calibratedWhite: 0.45, alpha: 1)
    let shCmd     = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.95, alpha: 1)

    let keywords: Set<String> = ["if","then","else","elif","fi","for","while","do","done","case","esac","in","function","return","exit","export","local","set","unset","source","eval"]

    let lines = cmd.components(separatedBy: "\n")
    for (li, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            result.append(NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: shComment]))
        } else {
            var idx = line.startIndex
            var firstWord = true
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == "\"" || ch == "'" {
                    var end = line.index(after: idx)
                    while end < line.endIndex && line[end] != ch { end = line.index(after: end) }
                    if end < line.endIndex { end = line.index(after: end) }
                    result.append(NSAttributedString(string: String(line[idx..<end]), attributes: [.font: mono, .foregroundColor: shString]))
                    idx = end; firstWord = false
                } else if ch == "|" || ch == ";" || ch == ">" || ch == "<" {
                    result.append(NSAttributedString(string: String(ch), attributes: [.font: mono, .foregroundColor: shPipe]))
                    idx = line.index(after: idx); firstWord = true
                } else if ch == "&" && line.index(after: idx) < line.endIndex && line[line.index(after: idx)] == "&" {
                    result.append(NSAttributedString(string: "&&", attributes: [.font: mono, .foregroundColor: shPipe]))
                    idx = line.index(idx, offsetBy: 2); firstWord = true
                } else if ch.isWhitespace {
                    result.append(NSAttributedString(string: String(ch), attributes: [.font: mono, .foregroundColor: codeTxt]))
                    idx = line.index(after: idx)
                } else {
                    var end = line.index(after: idx)
                    while end < line.endIndex && !line[end].isWhitespace && line[end] != "|" && line[end] != ";" && line[end] != "\"" && line[end] != "'" && line[end] != ">" && line[end] != "<" { end = line.index(after: end) }
                    let word = String(line[idx..<end])
                    let color: NSColor
                    if word.hasPrefix("-") { color = shFlag }
                    else if keywords.contains(word) { color = shKeyword }
                    else if firstWord { color = shCmd }
                    else { color = codeTxt }
                    result.append(NSAttributedString(string: word, attributes: [.font: mono, .foregroundColor: color]))
                    idx = end; firstWord = false
                }
            }
        }
        if li < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: mono])) }
    }
    return result
}

// Diff colors — matching terminal: green +, red -, white context
let rmFg      = NSColor(calibratedRed: 1.0,  green: 0.35, blue: 0.35, alpha: 1.0)
let addFg     = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.45, alpha: 1.0)
let ctxColor  = NSColor(calibratedWhite: 0.88, alpha: 1.0)
let gutterClr = NSColor(calibratedWhite: 0.38, alpha: 1.0)
let ellipClr  = NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.90, alpha: 1.0)
let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

// MARK: - Line diff (LCS-based, matching terminal's Myers output)

enum DiffOp { case ctx(String), rm(String), add(String) }

func lineDiff(_ oldStr: String, _ newStr: String) -> [DiffOp] {
    let a = oldStr.components(separatedBy: "\n")
    let b = newStr.components(separatedBy: "\n")
    let m = a.count, n = b.count

    // LCS table
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m { for j in 1...n {
        dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
    }}

    // Backtrack
    var ops = [DiffOp]()
    var i = m, j = n
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && a[i-1] == b[j-1] {
            ops.append(.ctx(a[i-1])); i -= 1; j -= 1
        } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
            ops.append(.add(b[j-1])); j -= 1
        } else {
            ops.append(.rm(a[i-1])); i -= 1
        }
    }
    ops.reverse()

    // Collapse long context runs (>5 unchanged lines)
    var result = [DiffOp]()
    var ctxRun = [String]()
    func flushCtx() {
        if ctxRun.count <= 5 {
            for c in ctxRun { result.append(.ctx(c)) }
        } else {
            for c in ctxRun.prefix(3) { result.append(.ctx(c)) }
            result.append(.ctx("\u{2026}"))
            for c in ctxRun.suffix(2) { result.append(.ctx(c)) }
        }
        ctxRun.removeAll()
    }
    for op in ops {
        if case .ctx(let l) = op { ctxRun.append(l) } else { flushCtx(); result.append(op) }
    }
    flushCtx()
    return result
}

// Find the starting line number of old_string in the file
func findStartLine(filePath: String, oldString: String) -> Int {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return 1 }
    let fileLines = content.components(separatedBy: "\n")
    let oldLines = oldString.components(separatedBy: "\n")
    guard let firstOld = oldLines.first else { return 1 }
    for (i, line) in fileLines.enumerated() {
        if line == firstOld {
            // Check if full match starts here
            let remaining = fileLines[i...]
            if remaining.count >= oldLines.count {
                let slice = Array(remaining.prefix(oldLines.count))
                if slice == oldLines { return i + 1 }
            }
        }
    }
    return 1
}

func buildContent() -> NSAttributedString {
    let r = NSMutableAttributedString()
    func lbl(_ t: String) { r.append(NSAttributedString(string: t + "\n", attributes: [.font: lblFont, .foregroundColor: lblClr])) }
    func file(_ t: String) { r.append(NSAttributedString(string: t + "\n", attributes: [.font: monoBold, .foregroundColor: fileClr])) }
    func code(_ t: String, c: NSColor = codeTxt, b: NSColor? = nil) {
        var a: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: c]
        if let b = b { a[.backgroundColor] = b }
        r.append(NSAttributedString(string: t + "\n", attributes: a))
    }
    func block(_ t: String, c: NSColor = codeTxt, b: NSColor? = nil) {
        for l in t.components(separatedBy: "\n") { code(l, c: c, b: b) }
    }
    func nl() { r.append(NSAttributedString(string: "\n")) }

    switch toolName {
    case "Bash":
        if let d = toolInput["description"] as? String, !d.isEmpty { lbl(d); nl() }
        if let c = toolInput["command"] as? String {
            r.append(highlightBash(c))
            r.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
        }
    case "Edit":
        let filePath = toolInput["file_path"] as? String ?? ""
        if !filePath.isEmpty { file(filePath); nl() }
        let old = toolInput["old_string"] as? String ?? ""
        let new = toolInput["new_string"] as? String ?? ""
        let ops = lineDiff(old, new)
        let startLine = findStartLine(filePath: filePath, oldString: old)

        // Calculate gutter width based on max line number
        let oldCount = old.components(separatedBy: "\n").count
        let newCount = new.components(separatedBy: "\n").count
        let maxLineNo = startLine + max(oldCount, newCount) + 5
        let gutterW = max(3, String(maxLineNo).count)

        var lineNo = startLine
        for op in ops {
            let s = NSMutableAttributedString()
            switch op {
            case .rm(let l):
                let num = String(format: "%\(gutterW)d", lineNo)
                s.append(NSAttributedString(string: "\(num) ", attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                s.append(NSAttributedString(string: "- ", attributes: [.font: mono, .foregroundColor: rmFg]))
                s.append(NSAttributedString(string: l + "\n", attributes: [.font: mono, .foregroundColor: rmFg]))
                lineNo += 1
            case .add(let l):
                let num = String(format: "%\(gutterW)d", lineNo)
                s.append(NSAttributedString(string: "\(num) ", attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                s.append(NSAttributedString(string: "+ ", attributes: [.font: mono, .foregroundColor: addFg]))
                s.append(NSAttributedString(string: l + "\n", attributes: [.font: mono, .foregroundColor: addFg]))
                lineNo += 1
            case .ctx(let l):
                if l == "\u{2026}" {
                    let pad = String(repeating: " ", count: gutterW)
                    s.append(NSAttributedString(string: "\(pad)   ...\n", attributes: [.font: mono, .foregroundColor: ellipClr]))
                } else {
                    let num = String(format: "%\(gutterW)d", lineNo)
                    s.append(NSAttributedString(string: "\(num) ", attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                    s.append(NSAttributedString(string: "  ", attributes: [.font: mono, .foregroundColor: ctxColor]))
                    s.append(NSAttributedString(string: l + "\n", attributes: [.font: mono, .foregroundColor: ctxColor]))
                    lineNo += 1
                }
            }
            r.append(s)
        }
    case "Write":
        if let f = toolInput["file_path"] as? String { file(f); nl() }
        if let c = toolInput["content"] as? String {
            let lines = c.components(separatedBy: "\n")
            for l in lines.prefix(50) { code(l) }
            if lines.count > 50 { lbl("... (\(lines.count - 50) more lines)") }
        }
    case "Read":
        if let f = toolInput["file_path"] as? String { file(f) }
        if let o = toolInput["offset"] as? Int { lbl("offset: \(o)") }
        if let l = toolInput["limit"] as? Int { lbl("limit: \(l)") }
    case "NotebookEdit":
        if let f = toolInput["notebook_path"] as? String { file(f) }
        if let m = toolInput["edit_mode"] as? String { lbl("mode: \(m)") }
        nl()
        if let s = toolInput["new_source"] as? String { block(s) }
    case "Task":
        if let d = toolInput["description"] as? String { lbl(d) }
        if let t = toolInput["subagent_type"] as? String { lbl("agent: \(t)") }
        nl()
        if let p = toolInput["prompt"] as? String { block(p) }
    case "WebFetch":
        if let u = toolInput["url"] as? String { file(u); nl() }
        if let p = toolInput["prompt"] as? String { block(p) }
    case "WebSearch":
        if let q = toolInput["query"] as? String { block(q) }
    case "Glob":
        if let p = toolInput["pattern"] as? String { code(p) }
        if let d = toolInput["path"] as? String { lbl("in: \(d)") }
    case "Grep":
        if let p = toolInput["pattern"] as? String { code(p) }
        if let d = toolInput["path"] as? String { lbl("in: \(d)") }
        if let g = toolInput["glob"] as? String { lbl("glob: \(g)") }
    default:
        if let data = try? JSONSerialization.data(withJSONObject: toolInput, options: .prettyPrinted),
           let s = String(data: data, encoding: .utf8) { block(s) }
    }
    return r
}

// MARK: - Result

var dialogResult = "deny"

// MARK: - Options (same as Claude Code's native permission prompt)

struct PermOption {
    let label: String
    let result: String
    let color: NSColor
}

let optGreen  = NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.45, alpha: 1.0)
let optBlue   = NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.90, alpha: 1.0)
let optAmber  = NSColor(calibratedRed: 0.85, green: 0.65, blue: 0.20, alpha: 1.0)
let optRed    = NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)

let permOptions: [PermOption] = [
    PermOption(label: "Allow once",                        result: "allow_once",    color: optGreen),
    PermOption(label: "Allow \(toolName) this session",    result: "allow_session", color: optBlue),
    PermOption(label: "Always allow \(toolName)",          result: "always_allow",  color: optAmber),
    PermOption(label: "Reject",                            result: "deny",          color: optRed),
]

// MARK: - Build Window

let pw: CGFloat = 580
let optH: CGFloat = 30
let optGap: CGFloat = 6

// --- Determine button layout: pack into rows ---
let btnFont = NSFont.systemFont(ofSize: 12, weight: .medium)
let btnPad: CGFloat = 20
let btnMargin: CGFloat = 12
let availW = pw - btnMargin * 2

let btnNaturalWidths = permOptions.map { opt in
    (opt.label as NSString).size(withAttributes: [.font: btnFont]).width + btnPad * 2
}

// Greedily pack buttons into rows
var rows: [[Int]] = [[]]
var rowW: CGFloat = 0
for i in 0..<permOptions.count {
    let needed = btnNaturalWidths[i] + (rows[rows.count - 1].isEmpty ? 0 : optGap)
    if !rows[rows.count - 1].isEmpty && rowW + needed > availW {
        rows.append([i])
        rowW = btnNaturalWidths[i]
    } else {
        rows[rows.count - 1].append(i)
        rowW += needed
    }
}
let numRows = rows.count
let optionsRowH = CGFloat(numRows) * optH + CGFloat(max(0, numRows - 1)) * optGap + 12

// --- Measure content height first ---
let contentAttr = buildContent()
let measureTS = NSTextStorage(attributedString: contentAttr)
let measureLay = NSLayoutManager(); measureTS.addLayoutManager(measureLay)
let measureTC = NSTextContainer(size: NSSize(width: pw - 32 - 2 - 22, height: .greatestFiniteMagnitude))
measureTC.widthTracksTextView = true; measureLay.addTextContainer(measureTC)
measureLay.ensureLayout(for: measureTC)
let naturalContentH = measureLay.usedRect(for: measureTC).height + 24

// Clamp: min 36, max 400
let screenH = NSScreen.main?.visibleFrame.height ?? 800
let maxContentH = min(400, screenH * 0.5)
let codeBlockH = max(36, min(naturalContentH, maxContentH))

// Total: top(10) + header(20) + gap(6) + sep(1) + gist(18) + gap(4) + code + gap(8) + buttons row + bottom(6)
let fixedChrome: CGFloat = 10 + 20 + 6 + 1 + 18 + 4 + 8 + 6
let ph = fixedChrome + codeBlockH + optionsRowH

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: pw, height: ph),
    styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
    backing: .buffered, defer: false
)
panel.title = "Claude Code"
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isMovableByWindowBackground = true
panel.backgroundColor = bgColor
panel.titlebarAppearsTransparent = true
panel.titleVisibility = .hidden
panel.appearance = NSAppearance(named: .darkAqua)
// Center on screen
if let screen = NSScreen.main {
    let sf = screen.visibleFrame
    let x = sf.midX - pw / 2
    let y = sf.midY - ph / 2
    panel.setFrameOrigin(NSPoint(x: x, y: y))
} else {
    panel.center()
}

let cv = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
cv.wantsLayer = true
cv.layer?.backgroundColor = bgColor.cgColor
panel.contentView = cv

var yp = ph - 10

// Header
yp -= 20
let tl = NSTextField(labelWithString: "\(toolName)  —  \(sessionFull)")
tl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
tl.textColor = textPri
tl.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 18)
tl.lineBreakMode = .byTruncatingTail
cv.addSubview(tl)

yp -= 6
let sep = NSBox(frame: NSRect(x: 12, y: yp, width: pw - 24, height: 1))
sep.boxType = .separator
cv.addSubview(sep)

// Gist line
yp -= 18
let gistLabel = NSTextField(labelWithString: buildGist())
gistLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
gistLabel.textColor = textSec
gistLabel.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 16)
gistLabel.lineBreakMode = .byTruncatingTail
cv.addSubview(gistLabel)

// Code block (sized to content)
yp -= 4
let codeTop = yp
let codeBot = codeTop - codeBlockH
let cH = codeBlockH

let cb = NSView(frame: NSRect(x: 12, y: codeBot, width: pw - 24, height: cH))
cb.wantsLayer = true
cb.layer?.backgroundColor = codeBg.cgColor
cb.layer?.cornerRadius = 6
cb.layer?.borderWidth = 1
cb.layer?.borderColor = borderClr.cgColor
cv.addSubview(cb)

let sv = NSScrollView(frame: NSRect(x: 1, y: 1, width: cb.frame.width - 2, height: cb.frame.height - 2))
sv.hasVerticalScroller = true; sv.autohidesScrollers = true
sv.drawsBackground = false; sv.borderType = .noBorder

let ts = NSTextStorage(attributedString: contentAttr)
let lay = NSLayoutManager(); ts.addLayoutManager(lay)
let tc = NSTextContainer(size: NSSize(width: sv.frame.width - 22, height: .greatestFiniteMagnitude))
tc.widthTracksTextView = true; lay.addTextContainer(tc)

let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: sv.frame.width, height: sv.frame.height), textContainer: tc)
tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
tv.textContainerInset = NSSize(width: 8, height: 8); tv.autoresizingMask = [.width]
tv.textStorage?.setAttributedString(contentAttr)
lay.ensureLayout(for: tc)
tv.frame.size.height = max(lay.usedRect(for: tc).height + 20, sv.frame.height)
sv.documentView = tv; cb.addSubview(sv)

// --- Option buttons (generic row layout) ---
class BH: NSObject {
    static let shared = BH()
    @objc func clicked(_ sender: NSButton) {
        dialogResult = permOptions[sender.tag].result
        NSApp.stopModal()
    }
}

for (rowIdx, row) in rows.enumerated() {
    let rowY = codeBot - 8 - optH - CGFloat(rowIdx) * (optH + optGap)
    let gaps = optGap * CGFloat(max(0, row.count - 1))
    let bw = (availW - gaps) / CGFloat(row.count)
    for (col, i) in row.enumerated() {
        let bx = btnMargin + CGFloat(col) * (bw + optGap)
        let opt = permOptions[i]
        let btn = NSButton(frame: NSRect(x: bx, y: rowY, width: bw, height: optH))
        btn.title = opt.label
        btn.alignment = .center
        btn.bezelStyle = .rounded; btn.isBordered = false; btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.backgroundColor = opt.color.withAlphaComponent(0.08).cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = opt.color.withAlphaComponent(0.25).cgColor
        btn.contentTintColor = opt.color
        btn.font = btnFont; btn.tag = i
        btn.target = BH.shared; btn.action = #selector(BH.clicked(_:))
        cv.addSubview(btn)
        if i == 0 { panel.defaultButtonCell = btn.cell as? NSButtonCell }
    }
}

// Keyboard: 1-4 to select, Enter = first option, Esc = reject
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let key = event.charactersIgnoringModifiers ?? ""
    if let n = Int(key), n >= 1, n <= permOptions.count {
        dialogResult = permOptions[n - 1].result; NSApp.stopModal(); return nil
    }
    if key == "\r" { dialogResult = permOptions[0].result; NSApp.stopModal(); return nil }
    if key == "\u{1b}" { dialogResult = "deny"; NSApp.stopModal(); return nil }
    return event
}

DispatchQueue.main.asyncAfter(deadline: .now() + 600) { dialogResult = "deny"; NSApp.stopModal() }

// MARK: - Run

app.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
app.runModal(for: panel)
panel.orderOut(nil)

// MARK: - Handle result

var decision = "deny"
var reason = "Rejected via dialog"

switch dialogResult {
case "allow_once":
    decision = "allow"
    reason = "Allowed once via dialog"

case "allow_session":
    decision = "allow"
    reason = "Allowed \(toolName) for this session"
    let dir = "/tmp/claude-hook-sessions"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let fh = FileHandle(forWritingAtPath: sessionFile) {
        fh.seekToEndOfFile()
        fh.write("\(toolName)\n".data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: sessionFile, contents: "\(toolName)\n".data(using: .utf8))
    }

case "always_allow":
    decision = "allow"
    reason = "Always allowed \(toolName)"
    let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    if let data = FileManager.default.contents(atPath: settingsPath),
       var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       var perms = json["permissions"] as? [String: Any],
       var allow = perms["allow"] as? [String] {
        if !allow.contains(toolName) {
            allow.append(toolName)
            perms["allow"] = allow
            json["permissions"] = perms
            if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: URL(fileURLWithPath: settingsPath))
            }
        }
    }

default:
    decision = "deny"
    reason = "Rejected via dialog"
}

let output: [String: Any] = ["hookSpecificOutput": [
    "hookEventName": "PreToolUse",
    "permissionDecision": decision,
    "permissionDecisionReason": reason
]]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: output))
exit(0)

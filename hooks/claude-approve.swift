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
let lblFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

// MARK: - Gist (one-line summary)

func buildGist() -> String {
    switch toolName {
    case "Bash":
        let cmd = toolInput["command"] as? String ?? ""
        if let desc = toolInput["description"] as? String, !desc.isEmpty {
            return desc
        }
        // Extract just command names joined by operators
        let line = cmd.components(separatedBy: "\n").first ?? cmd
        var summary = [String]()
        var remaining = line.trimmingCharacters(in: .whitespaces)
        while !remaining.isEmpty {
            var matched = false
            for op in ["&&", "||", "|", ";"] {
                if let range = remaining.range(of: " \(op) ") {
                    let seg = String(remaining[remaining.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let name = seg.components(separatedBy: .whitespaces).first ?? seg
                    if !name.isEmpty { summary.append(name) }
                    summary.append(op)
                    remaining = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    matched = true; break
                }
            }
            if !matched {
                let name = remaining.components(separatedBy: .whitespaces).first ?? remaining
                if !name.isEmpty { summary.append(name) }
                break
            }
        }
        return summary.joined(separator: " ")
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
        // Description already shown in gist — content area only shows the command
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

// MARK: - Options (dynamically generated per tool type, matching Claude Code's native prompts)

struct PermOption {
    let label: String
    let result: String
    let color: NSColor
}

let optGreen  = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1.0)
let optBlue   = NSColor(calibratedRed: 0.30, green: 0.56, blue: 1.0,  alpha: 1.0)
let optRed    = NSColor(calibratedRed: 1.0,  green: 0.32, blue: 0.32, alpha: 1.0)

func buildPermOptions() -> [PermOption] {
    switch toolName {
    case "Bash":
        let cmd = toolInput["command"] as? String ?? ""
        let firstWord = cmd.components(separatedBy: .whitespaces).first ?? cmd
        let prefix = firstWord.isEmpty ? "similar" : firstWord
        let projectName = (cwd as NSString).lastPathComponent
        return [
            PermOption(label: "Yes", result: "allow_once", color: optGreen),
            PermOption(label: "Yes, and don't ask again for \(prefix) commands in \(projectName)", result: "dont_ask_bash", color: optBlue),
            PermOption(label: "No, and tell Claude what to do differently", result: "deny", color: optRed),
        ]
    case "Edit", "Write":
        return [
            PermOption(label: "Yes", result: "allow_once", color: optGreen),
            PermOption(label: "Yes, allow all edits during this session", result: "allow_edits_session", color: optBlue),
            PermOption(label: "No, and tell Claude what to do differently", result: "deny", color: optRed),
        ]
    case "WebFetch":
        let urlStr = toolInput["url"] as? String ?? ""
        let domain = URL(string: urlStr)?.host ?? urlStr
        return [
            PermOption(label: "Yes", result: "allow_once", color: optGreen),
            PermOption(label: "Yes, and don't ask again for \(domain)", result: "dont_ask_domain", color: optBlue),
            PermOption(label: "No, and tell Claude what to do differently", result: "deny", color: optRed),
        ]
    case "WebSearch":
        return [
            PermOption(label: "Yes", result: "allow_once", color: optGreen),
            PermOption(label: "Yes, and don't ask again for WebSearch", result: "dont_ask_tool", color: optBlue),
            PermOption(label: "No, and tell Claude what to do differently", result: "deny", color: optRed),
        ]
    default:
        return [
            PermOption(label: "Yes", result: "allow_once", color: optGreen),
            PermOption(label: "Yes, during this session", result: "allow_session", color: optBlue),
            PermOption(label: "No, and tell Claude what to do differently", result: "deny", color: optRed),
        ]
    }
}

let permOptions = buildPermOptions()

// MARK: - Build Window

let pw: CGFloat = 580
let optH: CGFloat = 34
let optGap: CGFloat = 8

// --- Determine button layout: pack into rows ---
let btnFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
let btnPad: CGFloat = 20
let btnMargin: CGFloat = 12
let availW = pw - btnMargin * 2

let btnNaturalWidths = permOptions.map { opt in
    (opt.label as NSString).size(withAttributes: [.font: btnFont]).width + btnPad * 2
}

// Pack buttons into rows (max 2 per row)
let maxPerRow = 2
var rows: [[Int]] = [[]]
var rowW: CGFloat = 0
for i in 0..<permOptions.count {
    let needed = btnNaturalWidths[i] + (rows[rows.count - 1].isEmpty ? 0 : optGap)
    if !rows[rows.count - 1].isEmpty && (rowW + needed > availW || rows[rows.count - 1].count >= maxPerRow) {
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

// Clamp: min 0 (hidden if empty), max 400
let screenH = NSScreen.main?.visibleFrame.height ?? 800
let maxContentH = min(400, screenH * 0.5)
let hasContent = contentAttr.length > 0
let codeBlockH = hasContent ? max(36, min(naturalContentH, maxContentH)) : CGFloat(0)

// Total: top(14) + project(28) + path(18) + gap(10) + sep(1) + gap(10) + toolGist(26) + gap(8) + code + gap(10) + buttons + bottom(6)
let fixedChrome: CGFloat = 14 + 28 + 18 + 10 + 1 + 10 + 26 + 8 + 10 + 6
let ph = fixedChrome + codeBlockH + optionsRowH

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: pw, height: ph),
    styleMask: [.titled, .closable, .nonactivatingPanel],
    backing: .buffered, defer: false
)
panel.title = "Claude Code"
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isMovableByWindowBackground = true
panel.backgroundColor = bgColor
panel.titleVisibility = .visible
panel.appearance = NSAppearance(named: .darkAqua)
panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
panel.standardWindowButton(.zoomButton)?.isHidden = true
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

var yp = ph - 14

// Session identity — project name + path
yp -= 28
let projLabel = NSTextField(labelWithString: sessionName)
projLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
projLabel.textColor = textPri
projLabel.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 28)
projLabel.lineBreakMode = .byTruncatingTail
cv.addSubview(projLabel)

yp -= 18
let pathLabel = NSTextField(labelWithString: cwd)
pathLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
pathLabel.textColor = textSec
pathLabel.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 16)
pathLabel.lineBreakMode = .byTruncatingMiddle
cv.addSubview(pathLabel)

yp -= 10
let sep = NSBox(frame: NSRect(x: 12, y: yp, width: pw - 24, height: 1))
sep.boxType = .separator
cv.addSubview(sep)

yp -= 10  // gap after separator, before tool tag

// Tool tag + gist on the same line
let toolTagColors: [String: NSColor] = [
    "Bash": NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1),
    "Edit": NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.25, alpha: 1),
    "Write": NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.25, alpha: 1),
    "Read": NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.0, alpha: 1),
    "Task": NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.95, alpha: 1),
    "WebFetch": NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.85, alpha: 1),
    "WebSearch": NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.85, alpha: 1),
    "Glob": NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.85, alpha: 1),
    "Grep": NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.85, alpha: 1),
]
let tagColor = toolTagColors[toolName] ?? NSColor(calibratedWhite: 0.65, alpha: 1)
let tagFont = NSFont.systemFont(ofSize: 13, weight: .bold)

yp -= 26
let rowH: CGFloat = 26

// Tag pill: NSButton naturally centers text at any size
let tagTextW = (toolName as NSString).size(withAttributes: [.font: tagFont]).width
let tagW = tagTextW + 20
let tagH: CGFloat = 26
let tagPill = NSButton(frame: NSRect(x: 16, y: yp, width: tagW, height: tagH))
tagPill.title = toolName
tagPill.bezelStyle = .rounded
tagPill.isBordered = false
tagPill.wantsLayer = true
tagPill.layer?.cornerRadius = 5
tagPill.layer?.backgroundColor = tagColor.withAlphaComponent(0.18).cgColor
tagPill.font = tagFont
tagPill.contentTintColor = tagColor
tagPill.focusRingType = .none
tagPill.refusesFirstResponder = true
cv.addSubview(tagPill)

let gistLabel = NSTextField(labelWithString: buildGist())
gistLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
gistLabel.textColor = textPri
gistLabel.sizeToFit()
let gistNatH = gistLabel.frame.height
gistLabel.frame = NSRect(x: 16 + tagW + 10, y: yp + (rowH - gistNatH) / 2, width: pw - 42 - tagW, height: gistNatH)
gistLabel.lineBreakMode = .byTruncatingTail
cv.addSubview(gistLabel)

// Code block (sized to content, hidden if empty)
yp -= hasContent ? 8 : 0
let codeBot = yp - codeBlockH

if hasContent {
    let cb = NSView(frame: NSRect(x: 12, y: codeBot, width: pw - 24, height: codeBlockH))
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
}

// --- Option buttons (generic row layout) ---
class BH: NSObject {
    static let shared = BH()
    @objc func clicked(_ sender: NSButton) {
        dialogResult = permOptions[sender.tag].result
        NSApp.stopModal()
    }
}

for (rowIdx, row) in rows.enumerated() {
    let rowY = codeBot - 10 - optH - CGFloat(rowIdx) * (optH + optGap)
    let gaps = optGap * CGFloat(max(0, row.count - 1))
    let bw = (availW - gaps) / CGFloat(row.count)
    for (col, i) in row.enumerated() {
        let bx = btnMargin + CGFloat(col) * (bw + optGap)
        let opt = permOptions[i]
        let btn = NSButton(frame: NSRect(x: bx, y: rowY, width: bw, height: optH))
        btn.title = opt.label
        btn.alignment = .center
        btn.bezelStyle = .rounded; btn.isBordered = false; btn.wantsLayer = true
        btn.layer?.cornerRadius = 7
        btn.layer?.backgroundColor = opt.color.withAlphaComponent(0.18).cgColor
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

func saveToSessionFile(_ entry: String) {
    let dir = "/tmp/claude-hook-sessions"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let fh = FileHandle(forWritingAtPath: sessionFile) {
        fh.seekToEndOfFile()
        fh.write("\(entry)\n".data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: sessionFile, contents: "\(entry)\n".data(using: .utf8))
    }
}

func saveToLocalSettings(_ rule: String) {
    let settingsPath = cwd + "/.claude/settings.local.json"
    let settingsDir = cwd + "/.claude"
    try? FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
    var json: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: settingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        json = existing
    }
    var perms = json["permissions"] as? [String: Any] ?? [:]
    var allow = perms["allow"] as? [String] ?? []
    if !allow.contains(rule) { allow.append(rule) }
    perms["allow"] = allow
    json["permissions"] = perms
    if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        try? updated.write(to: URL(fileURLWithPath: settingsPath))
    }
}

switch dialogResult {
case "allow_once":
    decision = "allow"
    reason = "Allowed once via dialog"

case "allow_session":
    decision = "allow"
    reason = "Allowed \(toolName) for this session"
    saveToSessionFile(toolName)

case "allow_edits_session":
    decision = "allow"
    reason = "Allowed all edits for this session"
    saveToSessionFile("Edit")
    saveToSessionFile("Write")

case "dont_ask_bash":
    decision = "allow"
    let cmd = toolInput["command"] as? String ?? ""
    let prefix = cmd.components(separatedBy: .whitespaces).first ?? ""
    let rule = prefix.isEmpty ? "Bash(*)" : "Bash(\(prefix) *)"
    reason = "Allowed \(rule) for project"
    saveToLocalSettings(rule)

case "dont_ask_domain":
    decision = "allow"
    let urlStr = toolInput["url"] as? String ?? ""
    let domain = URL(string: urlStr)?.host ?? ""
    let rule = domain.isEmpty ? "WebFetch" : "WebFetch(domain:\(domain))"
    reason = "Allowed \(rule)"
    saveToLocalSettings(rule)

case "dont_ask_tool":
    decision = "allow"
    reason = "Allowed \(toolName) for project"
    saveToLocalSettings(toolName)

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

import AppKit
import Foundation

// MARK: - Read input from file (passed as argument)

guard CommandLine.arguments.count > 1 else { exit(0) }
let inputFile = CommandLine.arguments[1]
guard let inputData = FileManager.default.contents(atPath: inputFile),
      let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else { exit(0) }

let toolName  = input["tool_name"] as? String ?? "Tool"
let toolInput = input["tool_input"] as? [String: Any] ?? [:]
let cwd       = input["cwd"] as? String ?? ""
let markerFile = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let termApp    = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "Terminal"

let sessionName = (cwd as NSString).lastPathComponent
let sessionFull = "\(sessionName)  —  \(cwd)"

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
let fileClr   = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1.0)
let lblClr    = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.70, alpha: 1.0)

let mono     = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
let lblFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

// MARK: - Gist

func buildGist() -> String {
    switch toolName {
    case "Bash":
        let cmd = toolInput["command"] as? String ?? ""
        let first = cmd.components(separatedBy: "\n").first ?? cmd
        return first.count > 80 ? String(first.prefix(77)) + "..." : first
    case "Edit":
        return "Edit \(((toolInput["file_path"] as? String ?? "") as NSString).lastPathComponent)"
    case "Write":
        return "Write \(((toolInput["file_path"] as? String ?? "") as NSString).lastPathComponent)"
    case "Read":
        return "Read \(((toolInput["file_path"] as? String ?? "") as NSString).lastPathComponent)"
    case "NotebookEdit":
        return "Notebook \(((toolInput["notebook_path"] as? String ?? "") as NSString).lastPathComponent)"
    case "Task":
        return toolInput["description"] as? String ?? "Launch agent"
    case "WebFetch":
        return "Fetch \(toolInput["url"] as? String ?? "")"
    case "WebSearch":
        return "Search: \(toolInput["query"] as? String ?? "")"
    case "Glob":
        return "Find: \(toolInput["pattern"] as? String ?? "")"
    case "Grep":
        return "Grep: \(toolInput["pattern"] as? String ?? "")"
    default:
        return toolName
    }
}

// MARK: - Bash highlighting

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
            var idx = line.startIndex; var firstWord = true
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
                    let color: NSColor = word.hasPrefix("-") ? shFlag : keywords.contains(word) ? shKeyword : firstWord ? shCmd : codeTxt
                    result.append(NSAttributedString(string: word, attributes: [.font: mono, .foregroundColor: color]))
                    idx = end; firstWord = false
                }
            }
        }
        if li < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: mono])) }
    }
    return result
}

// MARK: - Diff

let rmFg      = NSColor(calibratedRed: 1.0,  green: 0.35, blue: 0.35, alpha: 1.0)
let addFg     = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.45, alpha: 1.0)
let ctxColor  = NSColor(calibratedWhite: 0.88, alpha: 1.0)
let gutterClr = NSColor(calibratedWhite: 0.38, alpha: 1.0)
let ellipClr  = NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.90, alpha: 1.0)
let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

enum DiffOp { case ctx(String), rm(String), add(String) }

func lineDiff(_ oldStr: String, _ newStr: String) -> [DiffOp] {
    let a = oldStr.components(separatedBy: "\n"), b = newStr.components(separatedBy: "\n")
    let m = a.count, n = b.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m { for j in 1...n { dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1]+1 : max(dp[i-1][j], dp[i][j-1]) } }
    var ops = [DiffOp](); var i = m, j = n
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && a[i-1] == b[j-1] { ops.append(.ctx(a[i-1])); i -= 1; j -= 1 }
        else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) { ops.append(.add(b[j-1])); j -= 1 }
        else { ops.append(.rm(a[i-1])); i -= 1 }
    }
    ops.reverse()
    var result = [DiffOp](); var ctxRun = [String]()
    func flush() {
        if ctxRun.count <= 5 { for c in ctxRun { result.append(.ctx(c)) } }
        else { for c in ctxRun.prefix(3) { result.append(.ctx(c)) }; result.append(.ctx("\u{2026}")); for c in ctxRun.suffix(2) { result.append(.ctx(c)) } }
        ctxRun.removeAll()
    }
    for op in ops { if case .ctx(let l) = op { ctxRun.append(l) } else { flush(); result.append(op) } }
    flush(); return result
}

func findStartLine(_ filePath: String, _ oldString: String) -> Int {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return 1 }
    let fileLines = content.components(separatedBy: "\n"), oldLines = oldString.components(separatedBy: "\n")
    guard let first = oldLines.first else { return 1 }
    for (i, line) in fileLines.enumerated() {
        if line == first && fileLines[i...].count >= oldLines.count && Array(fileLines[i...].prefix(oldLines.count)) == oldLines { return i + 1 }
    }
    return 1
}

// MARK: - Build content

func buildContent() -> NSAttributedString {
    let r = NSMutableAttributedString()
    func lbl(_ t: String) { r.append(NSAttributedString(string: t + "\n", attributes: [.font: lblFont, .foregroundColor: lblClr])) }
    func file(_ t: String) { r.append(NSAttributedString(string: t + "\n", attributes: [.font: monoBold, .foregroundColor: fileClr])) }
    func code(_ t: String, c: NSColor = codeTxt) { r.append(NSAttributedString(string: t + "\n", attributes: [.font: mono, .foregroundColor: c])) }
    func block(_ t: String) { for l in t.components(separatedBy: "\n") { code(l) } }
    func nl() { r.append(NSAttributedString(string: "\n")) }

    switch toolName {
    case "Bash":
        if let d = toolInput["description"] as? String, !d.isEmpty { lbl(d); nl() }
        if let c = toolInput["command"] as? String { r.append(highlightBash(c)); r.append(NSAttributedString(string: "\n", attributes: [.font: mono])) }
    case "Edit":
        let fp = toolInput["file_path"] as? String ?? ""; if !fp.isEmpty { file(fp); nl() }
        let old = toolInput["old_string"] as? String ?? "", new = toolInput["new_string"] as? String ?? ""
        let ops = lineDiff(old, new); let start = findStartLine(fp, old)
        let gw = max(3, String(start + max(old.components(separatedBy: "\n").count, new.components(separatedBy: "\n").count) + 5).count)
        var ln = start
        for op in ops {
            let s = NSMutableAttributedString()
            switch op {
            case .rm(let l):
                s.append(NSAttributedString(string: String(format: "%\(gw)d ", ln), attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                s.append(NSAttributedString(string: "- \(l)\n", attributes: [.font: mono, .foregroundColor: rmFg])); ln += 1
            case .add(let l):
                s.append(NSAttributedString(string: String(format: "%\(gw)d ", ln), attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                s.append(NSAttributedString(string: "+ \(l)\n", attributes: [.font: mono, .foregroundColor: addFg])); ln += 1
            case .ctx(let l):
                if l == "\u{2026}" { s.append(NSAttributedString(string: "\(String(repeating: " ", count: gw))   ...\n", attributes: [.font: mono, .foregroundColor: ellipClr])) }
                else { s.append(NSAttributedString(string: String(format: "%\(gw)d ", ln), attributes: [.font: gutterFont, .foregroundColor: gutterClr]))
                    s.append(NSAttributedString(string: "  \(l)\n", attributes: [.font: mono, .foregroundColor: ctxColor])); ln += 1 }
            }
            r.append(s)
        }
    case "Write":
        if let f = toolInput["file_path"] as? String { file(f); nl() }
        if let c = toolInput["content"] as? String { let ls = c.components(separatedBy: "\n"); for l in ls.prefix(50) { code(l) }; if ls.count > 50 { lbl("... (\(ls.count-50) more)") } }
    case "Read":
        if let f = toolInput["file_path"] as? String { file(f) }
        if let o = toolInput["offset"] as? Int { lbl("offset: \(o)") }
        if let l = toolInput["limit"] as? Int { lbl("limit: \(l)") }
    case "NotebookEdit":
        if let f = toolInput["notebook_path"] as? String { file(f) }
        if let m = toolInput["edit_mode"] as? String { lbl("mode: \(m)") }; nl()
        if let s = toolInput["new_source"] as? String { block(s) }
    case "Task":
        if let d = toolInput["description"] as? String { lbl(d) }
        if let t = toolInput["subagent_type"] as? String { lbl("agent: \(t)") }; nl()
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

// MARK: - Build Window (informational — no decision buttons)

let pw: CGFloat = 580
let bottomArea: CGFloat = 8  // just padding, no buttons

let contentAttr = buildContent()
let mTS = NSTextStorage(attributedString: contentAttr)
let mLay = NSLayoutManager(); mTS.addLayoutManager(mLay)
let mTC = NSTextContainer(size: NSSize(width: pw - 24 - 2 - 22, height: .greatestFiniteMagnitude))
mTC.widthTracksTextView = true; mLay.addTextContainer(mTC); mLay.ensureLayout(for: mTC)
let naturalH = mLay.usedRect(for: mTC).height + 24
let screenH = NSScreen.main?.visibleFrame.height ?? 800
let codeBlockH = max(36, min(naturalH, min(400, screenH * 0.5)))

let fixedChrome: CGFloat = 10 + 20 + 6 + 1 + 18 + 4 + 8 + 6
let ph = fixedChrome + codeBlockH + bottomArea

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
if let screen = NSScreen.main {
    let sf = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(x: sf.midX - pw/2, y: sf.midY - ph/2))
} else { panel.center() }

let cv = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
cv.wantsLayer = true; cv.layer?.backgroundColor = bgColor.cgColor
panel.contentView = cv

var yp = ph - 10

// Header
yp -= 20
let tl = NSTextField(labelWithString: "\(toolName)  —  \(sessionFull)")
tl.font = NSFont.systemFont(ofSize: 13, weight: .semibold); tl.textColor = textPri
tl.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 18); tl.lineBreakMode = .byTruncatingTail
cv.addSubview(tl)

yp -= 6
let sep = NSBox(frame: NSRect(x: 12, y: yp, width: pw - 24, height: 1)); sep.boxType = .separator; cv.addSubview(sep)

// Gist
yp -= 18
let gl = NSTextField(labelWithString: buildGist())
gl.font = NSFont.systemFont(ofSize: 11, weight: .medium); gl.textColor = textSec
gl.frame = NSRect(x: 16, y: yp, width: pw - 32, height: 16); gl.lineBreakMode = .byTruncatingTail
cv.addSubview(gl)

// Code block
yp -= 4
let codeBot = yp - codeBlockH
let cb = NSView(frame: NSRect(x: 12, y: codeBot, width: pw - 24, height: codeBlockH))
cb.wantsLayer = true; cb.layer?.backgroundColor = codeBg.cgColor; cb.layer?.cornerRadius = 6
cb.layer?.borderWidth = 1; cb.layer?.borderColor = borderClr.cgColor; cv.addSubview(cb)

let sv = NSScrollView(frame: NSRect(x: 1, y: 1, width: cb.frame.width - 2, height: cb.frame.height - 2))
sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.drawsBackground = false; sv.borderType = .noBorder

let ts = NSTextStorage(attributedString: contentAttr)
let lay = NSLayoutManager(); ts.addLayoutManager(lay)
let tc = NSTextContainer(size: NSSize(width: sv.frame.width - 22, height: .greatestFiniteMagnitude))
tc.widthTracksTextView = true; lay.addTextContainer(tc)
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: sv.frame.width, height: sv.frame.height), textContainer: tc)
tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
tv.textContainerInset = NSSize(width: 8, height: 8); tv.autoresizingMask = [.width]
tv.textStorage?.setAttributedString(contentAttr); lay.ensureLayout(for: tc)
tv.frame.size.height = max(lay.usedRect(for: tc).height + 20, sv.frame.height)
sv.documentView = tv; cb.addSubview(sv)

// Keyboard: Esc to dismiss early
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.charactersIgnoringModifiers == "\u{1b}" { NSApp.stopModal(); return nil }
    return event
}

// Auto-close: poll marker file — when it's gone, terminal was answered
if !markerFile.isEmpty {
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        if !FileManager.default.fileExists(atPath: markerFile) { timer.invalidate(); NSApp.stopModal() }
    }
}
// Fallback timeout
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { NSApp.stopModal() }

// MARK: - Run

app.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
app.runModal(for: panel)
panel.orderOut(nil)

// Cleanup
try? FileManager.default.removeItem(atPath: inputFile)
exit(0)

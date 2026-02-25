///
///  harness.swift
///  Shared test infrastructure — assertions, stdout capture, temp dir helpers.
///
///  Compiled into both test-approve-bin and test-stop-bin.
///  Contains NO top-level executable code (the test files supply main).
///

import AppKit
import Foundation

// MARK: - Test State

var testsPassed = 0
var testsFailed = 0
var currentTest = ""

// MARK: - Test Runner

/// Registers and runs a single named test case.
func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    body()
}

// MARK: - Assertions

func assertEq<T: Equatable>(_ actual: T, _ expected: T,
                              file: String = #file, line: Int = #line) {
    if actual == expected {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("  FAIL [\(currentTest)] \(file):\(line)")
        print("    expected: \(expected)")
        print("    actual:   \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "",
                file: String = #file, line: Int = #line) {
    if condition {
        testsPassed += 1
    } else {
        testsFailed += 1
        let detail = msg.isEmpty ? "" : " — \(msg)"
        print("  FAIL [\(currentTest)] \(file):\(line)\(detail)")
    }
}

func assertFalse(_ condition: Bool, _ msg: String = "",
                 file: String = #file, line: Int = #line) {
    assertTrue(!condition, msg, file: file, line: line)
}

func assertContains(_ haystack: String, _ needle: String,
                    file: String = #file, line: Int = #line) {
    if haystack.contains(needle) {
        testsPassed += 1
    } else {
        testsFailed += 1
        let preview = haystack.count > 120 ? String(haystack.prefix(117)) + "..." : haystack
        print("  FAIL [\(currentTest)] \(file):\(line)")
        print("    \"\(preview)\" does not contain \"\(needle)\"")
    }
}

func assertNotContains(_ haystack: String, _ needle: String,
                       file: String = #file, line: Int = #line) {
    if !haystack.contains(needle) {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("  FAIL [\(currentTest)] \(file):\(line)")
        print("    string should NOT contain \"\(needle)\"")
    }
}

// MARK: - Stdout Capture

/// Redirects stdout to a pipe, runs `body`, and returns the captured output.
func captureStdout(_ body: () -> Void) -> String {
    fflush(stdout)
    let pipe = Pipe()
    let saved = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    body()
    fflush(stdout)
    dup2(saved, STDOUT_FILENO)
    close(saved)
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Temp Directory Helpers

/// Creates a unique temporary directory, passes its path to `body`, then removes it.
func withTempDir(_ body: (String) -> Void) {
    let dir = NSTemporaryDirectory()
        + "claude-test-\(ProcessInfo.processInfo.processIdentifier)"
        + "-\(Int.random(in: 100000..<999999))"
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(atPath: dir) }
    body(dir)
}

// MARK: - NSAttributedString Helpers

/// Returns the plain text from an attributed string.
func plainText(_ attr: NSAttributedString) -> String {
    attr.string
}

/// Returns the foreground color at the given character index.
func colorAt(_ attr: NSAttributedString, index: Int) -> NSColor? {
    guard index < attr.length else { return nil }
    return attr.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
}

/// Returns the font at the given character index.
func fontAt(_ attr: NSAttributedString, index: Int) -> NSFont? {
    guard index < attr.length else { return nil }
    return attr.attribute(.font, at: index, effectiveRange: nil) as? NSFont
}

/// Checks whether the font at `index` has the given symbolic trait.
func hasTrait(_ attr: NSAttributedString, at index: Int,
              trait: NSFontDescriptor.SymbolicTraits) -> Bool {
    guard let font = fontAt(attr, index: index) else { return false }
    return font.fontDescriptor.symbolicTraits.contains(trait)
}

// MARK: - Summary

/// Prints pass/fail summary and returns the exit code (0 = all passed, 1 = failures).
func printSummary() -> Int32 {
    let total = testsPassed + testsFailed
    if testsFailed > 0 {
        print("\n\(testsFailed) of \(total) tests FAILED")
        return 1
    } else {
        print("\nAll \(total) tests passed")
        return 0
    }
}

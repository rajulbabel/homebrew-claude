class Permit < Formula
  desc "Native macOS permission dialog for Claude Code"
  homepage "https://github.com/rajulbabel/homebrew-claude"
  url "https://github.com/rajulbabel/homebrew-claude.git", tag: "v1.1.1"
  version "1.1.1"
  license "MIT"

  depends_on :macos

  def install
    cd "hooks" do
      system "swiftc", "-framework", "AppKit",
             "-o", "claude-approve",
             "claude-approve.swift"
      system "swiftc", "-framework", "AppKit",
             "-o", "claude-notify",
             "claude-notify.swift"
      system "swiftc", "-framework", "AppKit",
             "-o", "claude-stop",
             "claude-stop.swift"
    end
    prefix.install "hooks"
    prefix.install "install.py"

    # Minimal background .app that runs install.py outside Homebrew's sandbox.
    # Launch Services starts it as a new process, bypassing sandbox-exec.
    app = prefix/"SetupHelper.app/Contents"
    (app/"MacOS").mkpath

    (app/"MacOS/setup").write <<~SH
      #!/bin/bash
      /usr/bin/python3 "#{prefix}/install.py"
      touch "/tmp/claude-permit-sentinel"
    SH
    (app/"MacOS/setup").chmod 0755

    (app/"Info.plist").write <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleExecutable</key>
        <string>setup</string>
        <key>CFBundleIdentifier</key>
        <string>com.claude-permit.setup</string>
        <key>LSBackgroundOnly</key>
        <true/>
        <key>LSUIElement</key>
        <true/>
      </dict>
      </plist>
    XML
  end

  def post_install
    sentinel = "/tmp/claude-permit-sentinel"
    File.delete(sentinel) if File.exist?(sentinel)

    system "open", "#{prefix}/SetupHelper.app"

    # Wait for the background .app to finish (up to 15 seconds)
    15.times do
      break if File.exist?(sentinel)
      sleep 1
    end
    File.delete(sentinel) if File.exist?(sentinel)
  end

  def uninstall
    system "/usr/bin/python3", "#{prefix}/install.py", "--uninstall"
  end

  test do
    assert_predicate prefix/"hooks/claude-approve", :exist?
  end

  def caveats
    <<~EOS
      Restart Claude Code for the hook to take effect.
    EOS
  end
end

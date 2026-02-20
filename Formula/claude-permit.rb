class ClaudePermit < Formula
  desc "Native macOS permission dialog for Claude Code"
  homepage "https://github.com/rajulbabel/.claude"
  url "https://github.com/rajulbabel/.claude.git", tag: "v1.0.0"
  version "1.0.0"
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
    end
    prefix.install "hooks"
    prefix.install "install.py"
    (bin/"claude-permit-setup").write <<~SH
      #!/bin/bash
      exec python3 "#{prefix}/install.py"
    SH
  end

  test do
    assert_predicate prefix/"hooks/claude-approve", :exist?
  end

  def caveats
    <<~EOS
      Run the setup command to install hooks into ~/.claude/:
        claude-permit-setup
      Then restart Claude Code for the hook to take effect.
    EOS
  end
end

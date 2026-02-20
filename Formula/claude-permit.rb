class ClaudePermit < Formula
  desc "Native macOS permission dialog for Claude Code"
  homepage "https://github.com/rajulbabel/.claude"
  url "https://github.com/rajulbabel/.claude/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
  license "MIT"

  depends_on :macos
  depends_on xcode: :build

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
  end

  def post_install
    system "python3", "#{prefix}/install.py"
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

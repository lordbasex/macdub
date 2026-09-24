# Homebrew cask for MacDub. Install from this repo's tap:
#   brew tap lordbasex/macdub https://github.com/lordbasex/macdub
#   brew install --cask macdub
# `scripts/release.sh` rewrites `version` and `sha256` on every release.
cask "macdub" do
  version "0.4.2"
  sha256 "733e9f109fdb31d2b323e7b6b2925afaaca18e9ee36fd5d1b872d12feb56ea40"

  url "https://github.com/lordbasex/macdub/releases/download/v#{version}/MacDub-#{version}.zip"
  name "MacDub"
  desc "Real-time, fully offline dubbing of any app's audio (Apple frameworks only)"
  homepage "https://github.com/lordbasex/macdub"

  depends_on macos: :sequoia

  app "MacDub.app"
  binary "#{appdir}/MacDub.app/Contents/Helpers/macdub-mcp"

  zap trash: [
    "~/Library/Application Support/MacDub",
    "~/Library/Preferences/com.lordbasex.MacDub.plist",
  ]

  caveats <<~EOS
    MacDub needs Screen & System Audio Recording and Speech Recognition permissions
    (System Settings › Privacy & Security). Grant them, then relaunch the app.

    MCP server for Claude Code / Claude Desktop / Codex (open MacDub once first, or use the
    "Add to Claude Code" button inside the app):
      claude mcp add --scope user macdub "$HOME/Library/Application Support/MacDub/bin/macdub-mcp"
  EOS
end

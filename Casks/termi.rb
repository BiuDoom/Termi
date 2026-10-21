# Homebrew Cask template for Termi
# Usage: brew install --cask termi (after adding the tap)
#
# To publish:
#   1. Create a GitHub repo: <your-user>/homebrew-tap
#   2. Place this file at Casks/termi.rb in that repo
#   3. Users add: brew tap <your-user>/tap
#   4. Then install: brew install --cask termi

cask "termi" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_DMG"

  url "https://github.com/YOUR_USER/Termi/releases/download/v#{version}/Termi-#{version}.dmg"
  name "Termi"
  desc "Native macOS SSH terminal client"
  homepage "https://github.com/YOUR_USER/Termi"

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Termi.app"

  zap trash: [
    "~/Library/Application Support/Termi",
    "~/Library/Preferences/dev.termi.Termi.plist",
    "~/.termi",
  ]
end

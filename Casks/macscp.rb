cask "macscp" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/tomaszkubiak-courses/macscp/releases/download/v#{version}/MacSCP-#{version}.dmg"
  name "MacSCP"
  desc "SFTP and SCP client with a dual-pane Commander window"
  homepage "https://github.com/tomaszkubiak-courses/macscp"

  livecheck do
    url "https://github.com/tomaszkubiak-courses/macscp/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "MacSCP.app"

  zap trash: [
    "~/Library/Application Support/MacSCP",
    "~/Library/Caches/MacSCP",
    "~/Library/Caches/io.github.tomaszkubiak-courses.MacSCP",
    "~/Library/Preferences/io.github.tomaszkubiak-courses.MacSCP.plist",
  ]
end

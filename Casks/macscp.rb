cask "macscp" do
  version "0.2.1"
  sha256 "766795e60a1fdb3abec7390b29976b7cac1b5d6218289701496c7a7796a47ccd"

  url "https://github.com/tomaszkubiak-courses/macscp/releases/download/v#{version}/MacSCP-#{version}.dmg"
  name "MacSCP"
  desc "SFTP and SCP client with a dual-pane Commander window"
  homepage "https://github.com/tomaszkubiak-courses/macscp"

  livecheck do
    url "https://github.com/tomaszkubiak-courses/macscp/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "MacSCP.app"

  zap trash: [
    "~/Library/Application Support/MacSCP",
    "~/Library/Caches/io.github.tomaszkubiak-courses.MacSCP",
    "~/Library/Caches/MacSCP",
    "~/Library/Preferences/io.github.tomaszkubiak-courses.MacSCP.plist",
  ]
end

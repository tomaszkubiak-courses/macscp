cask "macscp" do
  version "0.4.7"
  sha256 "95924bd639e15d2cb30e656a371e61765ee0912dc31c181b6f4f4c8140431edc"

  url "https://github.com/tomaszkubiak-courses/macscp/releases/download/v#{version}/MacSCP-#{version}.dmg"
  name "MacSCP"
  desc "SFTP, SCP, FTP, WebDAV and S3 client with a dual-pane Commander window"
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

cask "macscp" do
  version "0.3.0"
  sha256 "5b0d06c084cba47319d7a17fe8d9b80732768845e2f327a6cfb14b080ea89494"

  url "https://github.com/tomaszkubiak-courses/macscp/releases/download/v#{version}/MacSCP-#{version}.dmg"
  name "MacSCP"
  desc "SFTP, SCP, FTP and S3 client with a dual-pane Commander window"
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

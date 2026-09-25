cask "yap" do
  version "2.20-yap.2"
  sha256 "a34885582de7dab53295669df04fd95a5c68e3b2465aff328445159b3fe9d63b"

  url "https://github.com/Sma1lboy/yap/releases/download/v#{version}/Yap.zip"
  name "Yap"
  desc "Voice dictation with AI cleanup (fork of VoiceInk)"
  homepage "https://github.com/Sma1lboy/yap"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Yap.app"

  # ad-hoc 签名，没有经过苹果公证：去掉隔离标记才能直接打开
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Yap.app"]
  end

  zap trash: "~/Library/Preferences/me.sma1lboy.yap.plist"
end

cask "yap" do
  version "2.20-yap.1"
  sha256 :no_check # CI 发版后自动改成真实 sha256

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

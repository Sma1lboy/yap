cask "yap" do
  version "1.0.0"
  sha256 "c0e693c8b736c3880557b8139ceb0ea97a46afff2c0711da07870ed2b40f5af7"

  url "https://github.com/Sma1lboy/yap/releases/download/v#{version}/Yap.zip"
  name "Yap"
  desc "Voice dictation with AI cleanup (fork of VoiceInk)"
  homepage "https://github.com/Sma1lboy/yap"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Yap.app"

  # 自签名，没有经过苹果公证：去掉隔离标记才能直接打开；版本号和 sha256 由 CI 在打 tag 时更新
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Yap.app"]
  end

  zap trash: "~/Library/Preferences/me.sma1lboy.yap.plist"
end

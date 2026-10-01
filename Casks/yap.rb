# frozen_string_literal: true

cask "yap" do
  version "1.12.0"
  sha256 "8d0cf56d5e95ea89e999b9751aef5b855dfe0a1d03f0ccc1d6db030fdf84c10d"

  url "https://github.com/Sma1lboy/yap/releases/download/v#{version}/Yap.zip"
  name "Yap"
  desc "Voice dictation with AI cleanup (fork of VoiceInk)"
  homepage "https://github.com/Sma1lboy/yap"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Yap.app"

  # 1.3.0 起用 Developer ID 签名并经过苹果公证；下面去掉隔离标记是自签名时期留下的一步。版本号和 sha256 由 CI 在打 tag 时更新
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Yap.app"],
        writable_paths: ["Yap.app"],
        writable_base:  :appdir
  end

  zap trash: "~/Library/Preferences/me.sma1lboy.yap.plist"
end

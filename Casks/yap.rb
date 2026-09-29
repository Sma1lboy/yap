# frozen_string_literal: true

cask "yap" do
  version "1.6.1"
  sha256 "7340ca41ce54b9cffdb37d9f2021c612f514fae146a2a2ac888fa18a93292737"

  url "https://github.com/Sma1lboy/yap/releases/download/v#{version}/Yap.zip"
  name "Yap"
  desc "Voice dictation with AI cleanup (fork of VoiceInk)"
  homepage "https://github.com/Sma1lboy/yap"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Yap.app"

  # 自签名，没有经过苹果公证：去掉隔离标记才能直接打开；版本号和 sha256 由 CI 在打 tag 时更新
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Yap.app"],
        writable_paths: ["Yap.app"],
        writable_base:  :appdir
  end

  zap trash: "~/Library/Preferences/me.sma1lboy.yap.plist"
end

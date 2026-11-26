# Homebrew の tap（github.com/yteraoka/homebrew-cask の Formula/gcappy.rb）に置く formula の元。
# url と sha256 はリリースのワークフロー（scripts/formula.sh <version> <sha256> gcappy）が書き換える。
class Gcappy < Formula
  desc "Menu bar app for cappy: record meetings, then transcribe and summarize them"
  homepage "https://github.com/yteraoka/cappy"
  url "https://github.com/yteraoka/cappy/releases/download/v0.1.0/gcappy-0.1.0-macos-arm64.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    # gcappy.app には cappy（Contents/MacOS/cappy）も同梱している
    prefix.install "gcappy.app"
    # Launch Services 経由で起動する（直接実行するとターミナルの子プロセスになり、
    # 録音の許可がターミナルに対して求められるため）
    (bin/"gcappy").write <<~SH
      #!/bin/bash
      exec /usr/bin/open "#{opt_prefix}/gcappy.app" "$@"
    SH
    chmod 0755, bin/"gcappy"
  end

  def caveats
    <<~EOS
      gcappy.app was installed to:
        #{opt_prefix}/gcappy.app

      Start it from the menu bar with:
        gcappy

      To find it in Spotlight / Launchpad, link it into ~/Applications:
        mkdir -p ~/Applications && ln -sf #{opt_prefix}/gcappy.app ~/Applications/gcappy.app

      Use "Launch at Login" in the gcappy menu to start it automatically.
      The first recording asks gcappy for the "System Audio Recording" and
      "Microphone" permissions.
      Create the config file with `cappy init` (or "Run cappy init in Terminal..."
      in the menu) if you have not yet.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{prefix}/gcappy.app/Contents/MacOS/cappy --version").strip
    assert_predicate prefix/"gcappy.app/Contents/MacOS/gcappy", :executable?
  end
end

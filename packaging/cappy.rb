# Homebrew の自前 tap（例: github.com/yteraoka/homebrew-tap の Formula/cappy.rb）に置く formula の雛形。
# url と sha256 は scripts/release.sh の出力で更新する。
class Cappy < Formula
  desc "会議アプリの音声とマイク音声を別トラックで録音し、外部サービスで文字起こしする CLI"
  homepage "https://github.com/yteraoka/cappy"
  version "0.1.0"
  url "https://github.com/yteraoka/cappy/releases/download/v0.1.0/cappy-0.1.0-macos-arm64.zip"
  sha256 "REPLACE_WITH_SHA256"
  license "MIT"

  depends_on macos: :sequoia
  depends_on arch: :arm64

  def install
    bin.install "cappy"
  end

  def caveats
    <<~EOS
      初回の録音時に、実行元のターミナルアプリに対して
      「システムオーディオ録音」と「マイク」の許可を求めます。
      `cappy doctor` で権限・認証・設定を確認できます。
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/cappy --version")
  end
end

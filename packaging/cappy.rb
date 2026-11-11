# Homebrew の tap（github.com/yteraoka/homebrew-cask の Formula/cappy.rb）に置く formula の元。
# url と sha256 はリリースのワークフロー（scripts/formula.sh）が書き換える。
class Cappy < Formula
  desc "会議アプリの音声とマイク音声を別トラックで録音し、文字起こし・要約する CLI"
  homepage "https://github.com/yteraoka/cappy"
  url "https://github.com/yteraoka/cappy/releases/download/v0.1.0/cappy-0.1.0-macos-arm64.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    bin.install "cappy"
    # `cappy completion bash` / `cappy completion zsh` の出力を補完スクリプトとして置く
    generate_completions_from_executable(bin/"cappy", "completion", shells: [:bash, :zsh])
  end

  def caveats
    <<~EOS
      初回の録音時に、実行元のターミナルアプリに対して
      「システムオーディオ録音」と「マイク」の許可を求めます。
      `cappy doctor` で権限・認証・設定を確認できます。
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/cappy --version").strip
    assert_match "#compdef cappy", shell_output("#{bin}/cappy completion zsh")
  end
end

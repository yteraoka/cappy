# Homebrew の tap（github.com/yteraoka/homebrew-cask の Formula/cappy.rb）に置く formula の元。
# url と sha256 はリリースのワークフロー（scripts/formula.sh）が書き換える。
class Cappy < Formula
  desc "Record meeting audio and mic as separate tracks, then transcribe and summarize"
  homepage "https://github.com/yteraoka/cappy"
  url "https://github.com/yteraoka/cappy/releases/download/v0.1.0/cappy-0.1.0-macos-arm64.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    bin.install "cappy"
    # Install the output of `cappy completion bash` / `cappy completion zsh` as completion scripts
    generate_completions_from_executable(bin/"cappy", "completion", shells: [:bash, :zsh])
  end

  def caveats
    <<~EOS
      The first recording asks the terminal app you run cappy from for
      the "System Audio Recording" and "Microphone" permissions.
      Run `cappy init` to create the config file interactively, and
      `cappy doctor` to check permissions, authentication and settings.
      Set CAPPY_LANG=ja to show messages in Japanese.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/cappy --version").strip
    assert_match "#compdef cappy", shell_output("#{bin}/cappy completion zsh")
  end
end

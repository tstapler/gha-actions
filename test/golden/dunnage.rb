class Dunnage < Formula
  desc "Find and clean up disk space safely"
  homepage "https://github.com/tstapler/dunnage"
  license any_of: ["MIT", "Apache-2.0"]

  on_macos do
    depends_on arch: :arm64
    on_arm do
      url "https://github.com/tstapler/dunnage/releases/download/v0.1.0/dunnage-0.1.0-aarch64-apple-darwin.tar.gz"
      sha256 "1111111111111111111111111111111111111111111111111111111111111111"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/tstapler/dunnage/releases/download/v0.1.0/dunnage-0.1.0-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "3333333333333333333333333333333333333333333333333333333333333333"
    end
    on_intel do
      url "https://github.com/tstapler/dunnage/releases/download/v0.1.0/dunnage-0.1.0-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "2222222222222222222222222222222222222222222222222222222222222222"
    end
  end

  def install
    bin.install "dunnage"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/dunnage --version")
  end
end

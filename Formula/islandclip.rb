# Homebrew formula for IslandClip. Copy this file into your tap repo
# (github.com/YOUR_GITHUB_USER/homebrew-tap) at Formula/islandclip.rb.
#
# It builds from source on the user's machine, so the app is never
# downloaded as a binary, never gets the quarantine flag, and needs no
# paid Apple Developer account (it is ad-hoc signed during the build).
class Islandclip < Formula
  desc "Dynamic Island-style clipboard history, quick notes and Now Playing"
  homepage "https://github.com/YOUR_GITHUB_USER/IslandClip"
  url "https://github.com/YOUR_GITHUB_USER/IslandClip/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_TARBALL"
  license "MIT"

  depends_on macos: :ventura

  # Keep the helper dylib's @rpath install name. Otherwise Homebrew rewrites
  # it after install, which breaks the app's ad-hoc code signature.
  preserve_rpath

  def install
    # SwiftPM sandboxes manifest evaluation with sandbox-exec, which cannot
    # nest inside Homebrew's build sandbox, so it is disabled here (this is
    # what homebrew-core Swift formulas do). Homebrew already points HOME at a
    # temporary directory, so SwiftPM's caches stay inside the build area.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    ENV["OUTPUT_DIR"] = (buildpath/"build").to_s
    system "./scripts/build_app.sh"

    # Formulae can't write to /Applications; the app lives in the prefix and
    # the caveats explain how to link it.
    prefix.install "build/IslandClip.app"
  end

  def caveats
    <<~EOS
      IslandClip.app was installed to:
        #{opt_prefix}/IslandClip.app

      To make it show up in Launchpad/Spotlight, link it into ~/Applications:
        mkdir -p ~/Applications
        ln -sf "#{opt_prefix}/IslandClip.app" ~/Applications/IslandClip.app

      Launch it with:
        open "#{opt_prefix}/IslandClip.app"

      "Launch at Login" (menu bar icon) registers the app at its current path.
      Re-enable it after `brew upgrade islandclip` if it stops starting at login.
    EOS
  end

  test do
    app = prefix/"IslandClip.app"
    assert_predicate app/"Contents/MacOS/IslandClip", :executable?
    assert_path_exists app/"Contents/Frameworks/libIslandMediaHelper.dylib"
    plist = app/"Contents/Info.plist"
    assert_equal "com.example.islandclip",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{plist}").strip
    assert_equal "true", shell_output("/usr/libexec/PlistBuddy -c 'Print :LSUIElement' #{plist}").strip
    system "codesign", "--verify", "--deep", "--strict", app
  end
end

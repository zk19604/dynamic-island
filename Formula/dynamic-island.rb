# Homebrew formula for dynamic-island. Copy this file into your tap repo
# (github.com/zk19604/homebrew-tap) at Formula/dynamic-island.rb.
#
# It builds from source on the user's machine, so the app is never
# downloaded as a binary, never gets the quarantine flag, and needs no
# paid Apple Developer account (it is ad-hoc signed during the build).
class DynamicIsland < Formula
  desc "Notch island for the Mac: Now Playing, clipboard history and quick notes"
  homepage "https://github.com/zk19604/dynamic-island"
  url "https://github.com/zk19604/dynamic-island/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_TARBALL"
  license "MIT"

  depends_on macos: :ventura

  # Keep the helper dylib's @rpath install name. Otherwise Homebrew rewrites
  # it after install, which breaks the app's ad-hoc code signature.
  preserve_rpath

  def install
    # SwiftPM sandboxes manifest evaluation with sandbox-exec, which cannot
    # nest inside Homebrew's build sandbox, so it is disabled here (this is
    # what homebrew-core Swift formulae do). Homebrew already points HOME at a
    # temporary directory, so SwiftPM's caches stay inside the build area.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    ENV["OUTPUT_DIR"] = (buildpath/"build").to_s
    system "./scripts/build_app.sh"

    # Formulae can't write to /Applications; the app lives in the prefix and
    # the caveats explain how to link it.
    prefix.install "build/dynamic-island.app"
  end

  def caveats
    <<~EOS
      dynamic-island.app was installed to:
        #{opt_prefix}/dynamic-island.app

      Homebrew can't install apps into /Applications. Copy it there so it
      shows in Finder, Launchpad and Spotlight (symlinks are usually ignored):
        cp -R "#{opt_prefix}/dynamic-island.app" /Applications/
        open /Applications/dynamic-island.app

      After `brew upgrade dynamic-island`, quit the app and refresh the copy:
        rm -rf /Applications/dynamic-island.app
        cp -R "#{opt_prefix}/dynamic-island.app" /Applications/

      "Launch at Login" (menu bar icon) registers the copy you launched.
    EOS
  end

  test do
    app = prefix/"dynamic-island.app"
    assert_predicate app/"Contents/MacOS/dynamic-island", :executable?
    assert_path_exists app/"Contents/Frameworks/libIslandMediaHelper.dylib"
    assert_path_exists app/"Contents/Resources/AppIcon.icns"
    plist = app/"Contents/Info.plist"
    assert_equal "com.zk19604.dynamic-island",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{plist}").strip
    assert_equal "true", shell_output("/usr/libexec/PlistBuddy -c 'Print :LSUIElement' #{plist}").strip
    system "codesign", "--verify", "--deep", "--strict", app
  end
end

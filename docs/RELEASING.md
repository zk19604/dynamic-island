# Releasing IslandClip via your own Homebrew tap

IslandClip ships as a **build-from-source formula** in a personal tap.
Homebrew's official cask repo no longer accepts unsigned or un-notarized apps,
and a formula that compiles on the user's Mac needs no Apple Developer account.

Replace `YOUR_GITHUB_USER` everywhere below with your GitHub username.

## 1. Publish the app repo

```sh
cd IslandClip
git init
git add .
git commit -m "IslandClip 1.0.0"
gh repo create YOUR_GITHUB_USER/IslandClip --public --source . --push
# (or create the repo on github.com, then: git remote add origin … && git push -u origin main)
```

The formula points at `https://github.com/YOUR_GITHUB_USER/IslandClip`, so the
repo name matters.

## 2. Tag and create the release

```sh
git tag -a v1.0.0 -m "IslandClip 1.0.0"
git push origin v1.0.0
gh release create v1.0.0 --title "IslandClip 1.0.0" --notes "First release"
```

GitHub automatically provides the source tarball at:
`https://github.com/YOUR_GITHUB_USER/IslandClip/archive/refs/tags/v1.0.0.tar.gz`

## 3. Compute the sha256

Download the exact tarball Homebrew will download and hash it:

```sh
curl -L -o IslandClip-1.0.0.tar.gz \
  https://github.com/YOUR_GITHUB_USER/IslandClip/archive/refs/tags/v1.0.0.tar.gz
shasum -a 256 IslandClip-1.0.0.tar.gz
```

Copy the 64-character hex string. Do **not** hash a tarball you made yourself
with `tar` or `git archive`; it won't match GitHub's.

## 4. Create the tap repo

Homebrew maps `brew tap YOUR_GITHUB_USER/tap` to the GitHub repo
`YOUR_GITHUB_USER/homebrew-tap`.

```sh
gh repo create YOUR_GITHUB_USER/homebrew-tap --public --clone
cd homebrew-tap
mkdir -p Formula
cp ../IslandClip/Formula/islandclip.rb Formula/islandclip.rb
```

Edit `Formula/islandclip.rb`:

- replace `YOUR_GITHUB_USER` in `homepage` and `url`
- replace `REPLACE_WITH_SHA256_OF_THE_TARBALL` with the hash from step 3

Then:

```sh
git add Formula/islandclip.rb
git commit -m "islandclip 1.0.0"
git push
```

## 5. Test it

```sh
brew tap YOUR_GITHUB_USER/tap
brew install YOUR_GITHUB_USER/tap/islandclip      # compiles; takes a few minutes the first time
brew test islandclip
brew audit --strict --new islandclip
brew audit --strict --online YOUR_GITHUB_USER/tap/islandclip
ln -sf "$(brew --prefix)/opt/islandclip/IslandClip.app" ~/Applications/IslandClip.app
open ~/Applications/IslandClip.app
```

If you edit the formula locally, `brew reinstall --build-from-source islandclip`
rebuilds it.

## Shipping an update (e.g. 1.0.1)

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Commit, then `git tag -a v1.0.1 -m "1.0.1" && git push origin v1.0.1 && gh release create v1.0.1`.
3. Recompute the sha256 for the new tarball (step 3).
4. In the tap, update `url` (`v1.0.1`) and `sha256`, commit, and push.
5. Users run `brew upgrade islandclip`.

## Notes on the Homebrew build (already handled in the formula)

- **SwiftPM sandbox.** SwiftPM runs package manifests under `sandbox-exec`,
  which can't nest inside Homebrew's own build sandbox, so the formula passes
  `--disable-sandbox` (via `SWIFT_BUILD_FLAGS`), as homebrew-core Swift formulae do.
- **Caches and home directory.** Homebrew points `HOME` at a temporary
  directory during the build, so SwiftPM's caches and `.build` stay inside the
  build area. Nothing is written to your real home directory.
- **`preserve_rpath`.** Without it, Homebrew rewrites the helper dylib's
  install name after `install`. That fails (no header padding) and would also
  break the app's ad-hoc signature. With it, the signed bundle is installed
  untouched.
- **Location.** Formulae can't install into `/Applications`, so the app lives in
  `$(brew --prefix)/opt/islandclip/IslandClip.app` and the caveats explain
  the `~/Applications` symlink.
- **No quarantine.** The app is compiled locally, so Gatekeeper doesn't block
  it even though it's only ad-hoc signed.

# Releasing dynamic-island via your own Homebrew tap

dynamic-island ships as a **build-from-source formula** in a personal tap.
Homebrew's official cask repo no longer accepts unsigned or un-notarized apps,
and a formula that compiles on the user's Mac needs no Apple Developer account.

Commands below use the GitHub account `zk19604`.

## 1. Publish the app repo

```sh
cd dynamic-island
git init
git add .
git commit -m "dynamic-island 1.0.1"
gh repo create zk19604/dynamic-island --public --source . --push
# (or create the repo on github.com, then: git remote add origin … && git push -u origin main)
```

The formula points at `https://github.com/zk19604/dynamic-island`, so the
repo name matters.

## 2. Tag and create the release

```sh
git tag -a v1.0.1 -m "dynamic-island 1.0.1"
git push origin v1.0.1
gh release create v1.0.1 --title "dynamic-island 1.0.1" --notes "Renamed to dynamic-island, new icon"
```

GitHub automatically provides the source tarball at:
`https://github.com/zk19604/dynamic-island/archive/refs/tags/v1.0.1.tar.gz`

## 3. Compute the sha256

Download the exact tarball Homebrew will download and hash it:

```sh
curl -L -o dynamic-island-1.0.1.tar.gz \
  https://github.com/zk19604/dynamic-island/archive/refs/tags/v1.0.1.tar.gz
shasum -a 256 dynamic-island-1.0.1.tar.gz
```

Copy the 64-character hex string. Do **not** hash a tarball you made yourself
with `tar` or `git archive`; it won't match GitHub's.

## 4. Create the tap repo

Homebrew maps `brew tap zk19604/tap` to the GitHub repo
`zk19604/homebrew-tap`.

```sh
gh repo create zk19604/homebrew-tap --public --clone
cd homebrew-tap
mkdir -p Formula
cp ../dynamic-island/Formula/dynamic-island.rb Formula/dynamic-island.rb
```

Edit `Formula/dynamic-island.rb`:

- check `homepage` and `url` point at `zk19604/dynamic-island` and the right tag
- replace `REPLACE_WITH_SHA256_OF_THE_TARBALL` with the hash from step 3

Then:

```sh
git add Formula/dynamic-island.rb
git commit -m "dynamic-island 1.0.1"
git push
```

## 5. Test it

```sh
brew tap zk19604/tap
brew install zk19604/tap/dynamic-island      # compiles; takes a few minutes the first time
brew test dynamic-island
brew audit --strict --new dynamic-island
brew audit --strict --online zk19604/tap/dynamic-island
cp -R "$(brew --prefix)/opt/dynamic-island/dynamic-island.app" /Applications/
open /Applications/dynamic-island.app
```

If you edit the formula locally, `brew reinstall --build-from-source dynamic-island`
rebuilds it.

## Shipping an update (e.g. 1.0.2)

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Commit, then `git tag -a v1.0.2 -m "1.0.2" && git push origin v1.0.2 && gh release create v1.0.2`.
3. Recompute the sha256 for the new tarball (step 3).
4. In the tap, update `url` (`v1.0.2`) and `sha256`, commit, and push.
5. Users run `brew upgrade dynamic-island`.

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
  `$(brew --prefix)/opt/dynamic-island/dynamic-island.app`. The README tells
  users to copy it into `/Applications` (symlinks are usually ignored by
  Launchpad and Spotlight) and to repeat the copy after `brew upgrade`.
- **No quarantine.** The app is compiled locally, so Gatekeeper doesn't block
  it even though it's only ad-hoc signed.

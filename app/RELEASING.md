# Releasing Beat Key

Beat Key updates itself with Sparkle 2 (Beat Key › Check for Updates…, the daily automatic check,
and the check at the end of Run Doctor). It reads
`https://github.com/thuhmadhatter42/Orion/releases/latest/download/appcast.xml`, which GitHub
redirects to the `appcast.xml` asset of the newest non-draft, non-prerelease release. So every
release must carry an `appcast.xml`, or update checks fail with a 404.

## One-time setup (already done on the MacBook Pro, 2026-10-28)

- EdDSA signing key: `generate_keys --account beat-key` (Sparkle's tool, in
  `app/.build/artifacts/sparkle/Sparkle/bin/` after `swift package resolve`). The private key is
  in the login Keychain (account `beat-key`) and exported to
  `~/.config/beat-key/sparkle_ed25519_private` (chmod 600, outside the repo). build.sh signs
  with the exported file (override: `SPARKLE_ED_FILE=<path>`). Never commit or print it (backed up:
  on Sofia since 2026-10-29, signing keys in Passwords since 2026-11-09). Losing it means the next update must change the key and the Developer ID
  certificate cannot change in the same release (sparkle-project.org/documentation, "Rotating
  signing keys").
- Public key: `SUPublicEDKey` in `app/Info.plist`. `generate_keys --account beat-key -p` prints it.
- Notary profile `artemis-notary` in the login Keychain (`xcrun notarytool store-credentials`).

## Every release

1. Bump `VERSION` (last number +1). The version is both `CFBundleVersion` and
   `CFBundleShortVersionString`, and Sparkle compares it, so it must only go up.
2. Build: `app/build.sh`. It ends with `app/build/Beat-Key-<ver>.pkg`, the ONE installer: the download for
   people and the Sparkle update. It is signed (`Developer ID Installer: J Shriver (9WTFGV63S2)`, override
   `PKG_SIGN_IDENTITY`), notarized and stapled. `app/build/appcast.xml` has one item for that pkg, EdDSA-signed
   (`sign_update` on the pkg), enclosure
   `https://github.com/thuhmadhatter42/Orion/releases/download/Beat-Key-<ver>/Beat-Key-<ver>.pkg` with
   `sparkle:installationType="package"`. There is no DMG. `--no-notarize` stops after signing the pkg and writes no appcast.
3. Commit everything (the script needs HEAD on `main` with tracked files clean), then publish with
   `bash tools/publish.sh`, which reads `VERSION`. Since 0.1.62 it does all of this in three phases
   and logs to `app/build/publish-<ver>.log`:
   - checks, nothing changed anywhere: pkg stapled and signed (`pkgutil --check-signature`), `appcast.xml` names `<ver>`
     with the pkg as its enclosure, the tag `Beat-Key-<ver>` and the GitHub release do not exist yet, Sofia reachable and not
     already holding `Beat-Key-<ver>.pkg`;
   - publish: tag, push `main` and the tag, the pkg to Sofia
     `~/fourletterrecords/beat-key-releases/` (never overwrites), `beat-key-latest.json` =
     `{"version": "<ver>"}`, and last the GitHub release with the pkg and
     `appcast.xml` (the step every installed Beat Key sees). No restart of anything;
   - final check: `https://fourletterrecords.com/account/download/beat-key` answers 303 and
     `beat-key-latest.json` on Sofia names `<ver>`. Only then it prints `PUBLISHED <ver>`; any
     failure prints which public steps already happened.
   Auto mode may block public pushes; then J runs it: `! bash ~/dev/beatkey/tools/publish.sh`.
4. After it: `curl -sIL https://github.com/thuhmadhatter42/Orion/releases/latest/download/appcast.xml`
   ends in `200` and the file names `<ver>`.

## The pkg installer

`app/pkg/distribution.xml` + `app/pkg/postinstall`, assembled by build.sh (`pkgbuild` with a component
plist that sets `BundleIsRelocatable = false`, so it always installs `/Applications/Beat Key.app`;
`productbuild` signs it). The installer's `installation-check` (Installer JS
`system.applications.fromIdentifier('com.jshriver.orion')`, plus a scan of `system.applications.all()`
for an `Orion.app` / `Beat Key.app` bundle path) shows "Beat Key is open. Quit Beat Key, then click
Continue." while Beat Key runs. `postinstall` opens Beat Key as the logged-in console user. Both log
to `/var/log/install.log` (lines `JS: Beat Key check:` and `Beat Key postinstall:`).
An update is this same pkg, run ONCE, with one administrator password prompt: the appcast enclosure is the bare pkg, and
Sparkle (2.10.1, `Autoupdate/SUGuidedPackageInstaller.m`) runs `installer -pkg <pkg> -target /` as root after it has quit
Beat Key (`AppInstaller.m`: the install waits for the app to terminate), so `beatKeyClosedCheck` passes. A bare `.pkg` is
treated as a package update without the `sparkle:installationType` attribute (`SUAppcastItem.m`); build.sh writes
`sparkle:installationType="package"` anyway. Package updates need the EdDSA signature on the feed item and do not work in
unsigned dev builds (Sparkle 2.7.3 and later), so only a signed build counts. One launch: Sparkle relaunches Beat Key when it
is done, and `postinstall` does not open it when Sparkle's `Autoupdate` helper for `com.jshriver.orion` is running (it
opens it for a download run by hand). There is no second installer: no launch-time question, no Update Plug-ins menu item,
no plug-ins package inside the app.
Every launch, Beat Key also asks Sparkle for one background check (no timer).

### The plug-ins are choices in the same installer (plan step 16)

`app/pkg/plugin-pkgs.sh` packs the signed bundles from `plugin/build.noindex` (run by build.sh, which runs
`plugin/build.sh` first; `BEATKEY_PLUGINS_PREBUILT=1` skips that): `Beat-Key-AU.pkg` (to
`/Library/Audio/Plug-Ins/Components`), `Beat-Key-VST3.pkg` (`/Library/Audio/Plug-Ins/VST3`) and
`Beat-Key-AAX.pkg` (`/Library/Application Support/Avid/Audio/Plug-Ins`): plain payloads, root-owned, not
relocatable, one receipt each (`com.jshriver.orion.plugin.{au,vst3,aax}.pkg`). `distribution.xml` makes them
choices under Customize. `start_selected` is Installer JS (`plugInStartsTicked`): with no `/Applications/Beat Key.app` or
`Orion.app` (a fresh install) every plug-in starts ticked; with the app installed (an update) a plug-in starts ticked only
when its bundle is already on disk (the six paths in `uninstall.manifest`), so a format a user declined is never forced on
and a format they have is updated in the same run. `app/pkg/test.sh` evaluates this with `installer -showChoicesXML` on fixture
Macs. Each plug-in package has a postinstall that only reads and logs
(`app/pkg/plugin-postinstall`), like the app's: `/var/log/install.log` and `~/Library/Logs/Beat Key/install.log`.
- Refuses to package when the AAX is missing, its seal is broken, `plugin/build.noindex/AAX-NOT-PACE-SIGNED`
  exists (the file plugin/build.sh leaves when the AAX signing step did not run), or the verify script
  `~/.config/beat-key/aax-verify.sh` (outside the repo, if present) says no. `BEATKEY_SKIP_AAX=1` builds an
  installer with no AAX, and says so.
- After signing and again after notarizing, build.sh runs `plugin-pkgs.sh verify <pkg>`: the pkg is expanded and
  every bundle inside is re-checked with `codesign --verify --deep --strict`, and each must install where its
  format belongs.
- Dry run on the real signed bundles, nothing installed or notarized: `sh app/pkg/test.sh`
  (`BEATKEY_PLUGIN_BUILD=<plugin/build.noindex>` points it at built bundles from another checkout).

## Testing an update without publishing

Build the newer version with `APPCAST_DOWNLOAD_PREFIX=http://127.0.0.1:<port>/`, serve its pkg and
appcast with `python3 -m http.server <port> --bind 127.0.0.1`, point the installed older Beat Key at
it with `defaults write com.jshriver.orion SUFeedURL http://127.0.0.1:<port>/appcast.xml`, and
use Check for Updates…. Afterwards: `defaults delete com.jshriver.orion SUFeedURL`, stop the server.

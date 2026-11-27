# Session handoff: SideStep self-updating apps (2026-11-27)

## The goal
John (GitHub `johnbuckman`) distributes his own iOS apps with **SideStep**, his own
macOS menu-bar sideloader (`github.com/johnbuckman/SideStep`, AGPL, built on AltSign +
zsign). Today an app can only update when the iPhone is on the same network as the Mac,
because the Mac holds the Apple ID private key and does all signing and installing. He
wants apps to update themselves from GitHub from anywhere.

His idea: a small signed "loader" app that downloads the real app from GitHub Releases
into Documents and loads it, without re-signing on the Mac.

## How SideStep works today (read `docs/AI-BOOTSTRAP.md` and `docs/CURRENT-STATE.md` in SideStep)
- The user signs in with an Apple ID; one certificate per account is stored at
  `~/Library/Application Support/SideStep/cert-<sanitized appleid>.json` on the Mac
  (`{"serial","data": base64 DER cert, "key": base64 private key}`; see `CertStore` in
  `SideloaderKit/Sideloader.swift`).
- The Mac signs IPAs with zsign (`NativeBridge/Sources/native_bridge_zsign.cpp`) and installs
  over USB or Wi-Fi with libimobiledevice (`Helpers/idevice_ipinstall.c`).
- Every installed app gets the **BeaconInject** dylib (`BeaconInject/beacon_inject.m`). It
  pings the Mac (Bonjour, baked-in LAN IP `mac_ip` from `BeaconConfig.plist`, broadcast) on
  UDP 51234. The Mac's `SideloaderKit/BeaconListener.swift` binds INADDR_ANY, records the
  beacon's source IP (`DeviceIPCache`), re-signs and pushes the new build to that IP. The app
  `exit(0)`s after upload.
- Free Apple IDs: 7-day profiles, 3 app slots. Paid team `XLS3XF57J8` (Decent): 1 year.
- John's apps in the catalog (`sidestep-apps.json`): Stay on Track, iWish, Decently Fluent,
  Decent Timer, dcamp, Magnatune, Decent Cocktails, Decaid, de1app (de1app is Tcl). We
  haven't confirmed which are native Swift vs script/web-view based.
- SideStep repo convention: **don't commit or push to SideStep until John asks**; push to
  the `sidestep` remote, never `origin`.

## Conclusions reached
1. **iOS enforces code signing in the kernel, whatever the distribution route.** Skipping
   App Store review (John's apps never go through it) frees private APIs and policy-breaking
   techniques, but downloaded native code still won't run unless it's signed by a certificate
   the device trusts and has the same Team ID as the app. Zipping it changes nothing, and
   there is no writable+executable memory without a debugger attached.
2. **Interpreted payloads** (Tcl/JS/Lua, web views) can be downloaded into Documents and run
   freely; a generic "payload updater" could live in BeaconInject.
3. **Native payloads: sign on the phone.** The shell holds the user's private key, re-signs
   the downloaded dylib with zsign on the device, then `dlopen`s it. zsign only needs the key
   plus the app's own `embedded.mobileprovision`: it finds the matching certificate in the
   profile's `DeveloperCertificates`. This is SideStore's model, and SideStep's docs list
   on-device signing as an approach they had dropped, so it changes the security model (the
   private key lives on the phone). For John's own devices on the paid team, an alternative is
   signing the dylib in CI with his paid certificate (same Team ID), with no key on the phone.
4. Even with a loader, a **free account's 7-day profile** still needs the Mac to re-sign the
   shell. On the paid team (1 year) the loader removes the Mac almost entirely.
5. **Tailscale** (make the Mac reachable remotely) was explored. The code is nearly ready (the
   listener already accepts any source IP; the beacon would need a `mac_tailnet_ip`). John
   rejected it: he already runs his own VPN, and iOS allows only one. Open question: if *his*
   VPN connects into his home LAN, the same approach may work over it. Ask what kind of VPN.
6. TrollStore (CoreTrust bug, iOS 14.0–16.6.1 and 17.0) would allow anything on old iPads.
   Not pursued.

## What was built: `github.com/johnbuckman/sidestep-loader-test` (public)
A proof of concept for conclusion 3: is a dylib **signed on the phone** accepted by `dlopen`?

- `Shell/Loader.swift`, `Shell/App.swift`: SwiftUI app. It imports the key (SideStep's
  cert JSON, a .p12 or a PEM key) into the Keychain, downloads `payload.dylib` from the latest
  release, signs it with zsign, `dlopen`s it, calls `sidestep_payload_hello()`, and can show a
  view controller from `sidestep_payload_make_view_controller()`. A control step loads the
  unsigned copy, which iOS should refuse. The log is written to disk line by line (it survives
  a crash) and has a Copy button.
  Testing aids: a key dropped in Documents as `import-key.json|.p12|.pem` is auto-imported;
  `Documents/embedded.mobileprovision` is used when the app has no embedded profile
  (simulator); `file://` payload URLs work; the `-autorun` launch argument runs the test.
- `Shell/Signer/sst_signer.{h,cpp}`: C bridge `sst_sign_macho(macho, key, cert?, password,
  profile, identifier, logBuf, logLen)` using `ZSignAsset::Init(..., singleBinary=true)` +
  `ZMachO::Sign`.
- `Vendor/zsign/`: subset copied from SideStep `Dependencies/zsign` (identical to SideStep
  commit `4592943`). Two changes: a `g_zlogHook` log hook in `common/log.{h,cpp}`, and
  `system()` disabled on iOS in `common/util.cpp`.
- `Payload/payload.m`: the downloaded code; `PAYLOAD_VERSION` is the release tag.
- `project.yml` (XcodeGen; OpenSSL from `krzyzanowskim/OpenSSL` 3.6.2000, the same as SideStep)
  and `.github/workflows/build.yml` (macos-15: builds an unsigned IPA plus payload; on a `v*`
  tag it publishes a release with `LoaderTest.ipa` and `payload.dylib`; the payload URL is
  baked in as `releases/latest/download/payload.dylib`).
- `tests/sign_test.cpp`: desktop signer check.

### Verified so far
- zsign plus the bridge build on Linux; signing an arm64 iOS dylib with a throwaway cert chain
  and a fake profile passes zsign's `CheckSignature`.
- The app compiles for the iOS simulator on John's Mac (Xcode 26.6), and the GitHub Actions
  device build passes. **Release v1 is published** (both assets).
- **Not yet verified:** anything on a real device. That's the next step.

## Next steps
1. John installs v1 with SideStep (Install from GitHub: `johnbuckman/sidestep-loader-test`),
   AirDrops `cert-johnbuckmanmaccom.json` to the phone, imports it, taps **Run the whole
   test**, and pastes the log. Success: `✅ dlopen accepted the signed copy`, then
   `🎉 Payload says: payload v1…`, then `✅ As expected, iOS refused the unsigned copy`.
2. If it works: tag `v2` and confirm the app loads `payload v2` without reinstalling. Then
   design the real thing in SideStep: how the key reaches the shell (e.g. SideStep writes it
   into the app at install, next to `BeaconConfig.plist`), the shell/payload API boundary, the
   entitlement and Info.plist superset in the shell, signature verification of downloads
   (Ed25519 public key in the shell), rollback, and the CI-signing option for paid-team apps.
3. If `dlopen` refuses the signed copy: read the dyld error. Candidates: Team ID or library
   validation mismatch; the certificate zsign picked (check the `signer:` line in the log);
   the profile's entitlements embedded into the dylib (try signing without entitlements).
   AMFI may also refuse code mapped from the data container; if so, try other writable
   locations, or fall back to interpreted payloads or CI signing.

## Practicalities
- John's Mac is `john-m4` (macOS, Xcode 26.6, `gh` logged in as johnbuckman). Folders it
  offers to cloud sessions: `d` (his website repo; don't put test files there), `dcamp-ios`,
  `navim4`. The test project's working copy on the Mac is `/tmp/sidestep-loader-test`
  (a git checkout of the repo; pushes from there use his `gh` login). The Mac's shell is
  bash 3.2: avoid `$(cat <<EOF)`; use `git commit -F - <<'EOF'`.
- A cloud session's own GitHub credentials could not push to the new repo (`add_repo` with push
  access was refused), so pushes went through the Mac.
- John declined letting Claude read his SideStep key file on the Mac. Don't touch
  `cert-*.json` without asking. He handles key import on the phone himself.
- John's SideStep checkout on the Mac: `~/altstore-fork/AltSign-SS`, branch `isl-main`.
- Ask before outward-facing actions (creating repos, pushing to SideStep, releases beyond the
  test repo).

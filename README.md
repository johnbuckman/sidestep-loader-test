# SideStep loader test

Can a sideloaded iOS app download native code, sign it **on the phone** with the
user's own Apple ID key, and load it? This app tests exactly that.

1. GitHub Actions builds two things on every `v*` tag and attaches them to a release:
   - `LoaderTest.ipa`, an unsigned shell app you install once with SideStep;
   - `payload.dylib`, unsigned arm64 native code (Objective-C/UIKit).
2. On the phone, the shell downloads `payload.dylib` from the latest release, signs it
   with zsign using your private key and the certificate in its own provisioning
   profile, then loads it with `dlopen` and calls into it.
3. As a control, it also tries to load the unsigned download, which iOS should refuse.

## Running it

1. Install `LoaderTest.ipa` with SideStep (Install from GitHub, this repo).
2. On the Mac, AirDrop `~/Library/Application Support/SideStep/cert-<your Apple ID>.json`
   to the phone and save it to Files. It holds your signing key, so delete it from
   Files after importing. A `.p12` or PEM key works too.
3. In the app: **Import key file…**, then **Run the whole test**.
4. Success looks like `🎉 Payload says: payload v1, native code running on iOS …`, then
   `✅ As expected, iOS refused the unsigned copy`. Tap **Show the payload's screen**
   to see a UIKit screen drawn by the downloaded code.
5. Push tag `v2`, then run the test again **without reinstalling**: it should say `payload v2`.
   (SideStep may also update the shell itself when you're home; that's fine.)

The log is saved after every line, so if iOS kills the app during a test, reopen it to
read what happened. **Copy** puts the whole log on the clipboard.

## Layout

| Path | What |
|---|---|
| `Shell/Loader.swift` | Download, Keychain key storage, signing, `dlopen`, the control test |
| `Shell/App.swift` | SwiftUI screen |
| `Shell/Signer/sst_signer.*` | C bridge: sign one Mach-O file with zsign |
| `Vendor/zsign/` | zsign subset (MIT, copied from SideStep's `Dependencies/zsign`; changes: a log hook, and no `system()` on iOS) |
| `Payload/payload.m` | The downloaded code |
| `tests/sign_test.cpp` | Desktop check of the signer: `sign_test <dylib> <key> <profile> [cert]` |
| `project.yml` | XcodeGen spec (`xcodegen generate`) |

zsign is © zhlynn, MIT License (see `Vendor/zsign/LICENSE`).

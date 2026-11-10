# Distribution

HWYD follows the same distribution path as No Bleeding Eyes: a signed app in a DMG and ZIP on GitHub Releases, plus a versioned cask in `alepee/homebrew-tap`.

## Requirements

- Apple Silicon build host, Xcode 27 with Swift 6.4+ (required by the pinned dependencies).
- A persistent code signing certificate in the local keychain.
- GitHub CLI authentication with write access to `alepee/how-was-your-day` and `alepee/homebrew-tap`.
- A clean, committed working tree and release notes in English.

The signing private key stays on the maintainer's Mac. CI uses ad hoc signing for disposable artifacts only. No signing credentials or tap deploy keys are uploaded to GitHub by these scripts.

## Publish

Run the relevant tests first, then:

```sh
scripts/publish-release.sh 0.1.0 docs/releases/0.1.0.md
```

The script builds in `build/release`, leaving the running development app untouched. It sets the bundle version, verifies the signature, creates a DMG with an Applications shortcut, a ZIP and `SHA256SUMS`, pushes a tag and publishes the release. Finally it updates only the HWYD cask through GitHub's Contents API, with a SHA check to avoid overwriting concurrent edits.

The Homebrew update verifies that the published DMG digest matches the local file. If the release succeeds but the tap update fails, retry only:

```sh
python3 scripts/update-homebrew.py 0.1.0 build/release/HowWasYourDay.dmg
```

Existing releases are never overwritten. If publishing fails after the tag was pushed, inspect GitHub before retrying; publish the existing tag and artifacts with `gh release create --verify-tag`, then update the tap. Do not force-move a published tag.

## Signing status

Releases up to 0.4.0 used a persistent self-signed certificate. From 0.5.0 to 0.10.0, releases were signed with a personal-team `Apple Development` identity and were not notarized.

`scripts/publish-release.sh` now requires a `Developer ID Application` identity and notarizes the release: the app and both helpers are signed with the hardened runtime and a secure timestamp, the app is submitted to the notary service and stapled, then the DMG is signed, notarized and stapled. `spctl` checks both before publishing. Publishing without notarization needs `HWYD_ALLOW_UNNOTARIZED=1` and a different `SIGN_IDENTITY`.

The first notarized release changes the app's signing team, so macOS asks once more for microphone, audio capture and keychain access. Apple Speech reserves language models per application identity: after this change, check in Settings > Audio et voix that the installed languages are still listed, and reinstall them if needed (the download is skipped when macOS already has the model).

With several valid Developer ID certificates (after a renewal), set `SIGN_IDENTITY` to the SHA-1 of the one to use; the script refuses an ambiguous name.

### One-time setup

1. Create a `Developer ID Application` certificate (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com). Only the Account Holder can create it.
2. Create an app-specific password at account.apple.com, then store the notary credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials apple-notary --apple-id <apple-id> --team-id <team-id>
   ```

3. The profile is not specific to HWYD: other apps of the same team can notarize with it.
4. Check with `security find-identity -v -p codesigning` and `xcrun notarytool history --keychain-profile apple-notary`.

`SIGN_IDENTITY` and `NOTARY_PROFILE` override the defaults (`Developer ID Application`, `apple-notary`).

## CI and public files

GitHub Actions runs on `xcode-27` (Apple Silicon), runs core/pipeline tests and synthetic app checks, and publishes a short-lived CI ZIP. These artifacts are not user releases and must not be used to update the cask.

Build directories, audio, databases, signing keys and private calibration reports are ignored. The original architecture documents are retained in French. New public documentation and release notes are written in English; app localization is unchanged.

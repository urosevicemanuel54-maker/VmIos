# Vortex iOS app

This folder contains the Vortex SwiftUI app, Metal renderer, and native C CPU
core. The Xcode project is at the repository root.

## Build an unsigned IPA

Requires macOS with Xcode and the iOS 26 SDK installed:

```bash
bash scripts/build-vortex-ios.sh
```

The script creates `build/Vortex-unsigned.ipa`. It is unsigned and must be
signed with an appropriate Apple development or distribution identity before
installation. The Xcode deployment target is iOS 26.0, matching the JIT
integration requirements documented in [JIT/SETUP.md](JIT/SETUP.md).
Before signing, replace the placeholder bundle identifier in the Xcode target
build settings with an identifier registered to your Apple developer team.

## Build with GitHub Actions

Pushing the `build-vortex-ipa` branch runs the **Build Vortex unsigned IPA**
workflow on a macOS runner. Download the `Vortex-unsigned-IPA` artifact from
the completed run. The workflow packages an unsigned IPA; it does not sign or
install the app.

The app's JIT features require a development-signed or otherwise appropriately
provisioned build; an unsigned IPA alone does not grant those capabilities.

# VirtualiOS

An iPhone-hosted ARM64 virtualization research project.

## Current milestone: Stage 1 — native host app

This repository currently builds a minimal native SwiftUI iOS application and packages its app bundle into an **unsigned IPA** artifact.

This milestone does **not** include QEMU, a virtual machine monitor, an iOS 15 guest kernel, guest firmware, or SpringBoard. The app is a host-app foundation only.

## Build with GitHub Actions

1. Open the **Actions** tab in this repository.
2. Select **VirtualiOS - Stage 1 host app**.
3. Select **Run workflow**.
4. When the run completes, open its artifacts and download `VirtualiOS-Stage1`.

The artifact contains `VirtualiOS-unsigned.ipa`. It is unsigned; installing it on an iPhone requires signing it with a valid development or distribution identity.

## Build locally on macOS

Requires Xcode with the iOS SDK:

```bash
bash scripts/build-ios.sh
```

Output: `build/VirtualiOS-unsigned.ipa`

## Roadmap

- [x] Native SwiftUI host-app skeleton
- [x] Reproducible unsigned iOS app build in GitHub Actions
- [ ] Investigate and integrate an iOS-compatible ARM64 emulation engine
- [ ] Add VM lifecycle, memory, storage, display, and input layers
- [ ] Boot a compatible test guest
- [ ] Research the additional hardware, firmware, boot-chain, and security requirements for an iOS 15 guest

A generic ARM64 virtual machine is not an emulated iPhone. Booting a full iOS 15 system, including SpringBoard, is a separate and substantially harder research problem and is not promised by this project.

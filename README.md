# VirtualiOS

An iPhone-hosted ARM64 virtualization research project.

## Current milestone: Stage 2 — ARM64 QEMU TCI

The app builds an ARM64 QEMU TCG interpreter (TCI) engine from a pinned UTM QEMU integration. TCI avoids runtime JIT code generation, which is not generally available to ordinary iOS apps, but instruction emulation is very slow.

The app provides CPU and RAM configuration, Linux kernel and raw disk import, sparse raw disk creation, QEMU start/stop, QMP framebuffer screenshots, and a guest-error log console. Boot requires a compatible ARM64 Linux kernel. A raw disk alone is not bootable because this project does not bundle UEFI firmware.

This does not boot iOS 15, emulate iPhone hardware, or provide SpringBoard. QEMU-derived components are GPL-licensed; review their source and notices before redistributing the built IPA.

## Build with GitHub Actions

1. Open the **Actions** tab in this repository.
2. Select **VirtualiOS - Stage 2 ARM64 TCI host app**.
3. Select **Run workflow**.
4. When the run completes, download `VirtualiOS-Stage2` for the unsigned IPA or `VirtualiOS-QEMU-TCI-iOS-arm64` for the engine dylib.

The artifact contains `VirtualiOS-unsigned.ipa`. It is unsigned; installing it on an iPhone requires signing it with a valid development or distribution identity.

## Build locally on macOS

Requires Xcode, Homebrew, and the dependencies installed by `scripts/build-qemu-ios.sh`:

```bash
bash scripts/build-ios.sh
```

Output: `build/VirtualiOS-unsigned.ipa`

## Roadmap

- [x] Native SwiftUI host-app skeleton
- [ ] Verify the iOS ARM64 QEMU TCI engine build in GitHub Actions
- [x] Initial QEMU lifecycle bridge and VM configuration UI
- [ ] Validate an end-to-end Linux guest boot on a physical iPhone
- [ ] Add guest keyboard/input and richer framebuffer updates
- [ ] Research the additional hardware, firmware, boot-chain, and security requirements for an iOS 15 guest

A generic ARM64 virtual machine is not an emulated iPhone. Booting a full iOS 15 system, including SpringBoard, is a separate and substantially harder research problem and is not promised by this project.

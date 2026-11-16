# Vortex JIT setup

This file records exactly what the JIT integration in Vortex does, what it does
not do, and what a device needs for it to work.

## What is implemented

| Piece | State |
| --- | --- |
| Capability detection (iOS version, architecture, get-task-allow, CS_DEBUGGED, MAP_JIT executable memory, pairing file, LocalDevVPN endpoint) | Implemented, measured at runtime |
| Pairing file storage at `Documents/StikJIT/pairingFile.plist` | Implemented (complete file protection, excluded from backup, atomic replace) |
| Pairing file import through the Files picker | Implemented, structurally validated, contents never logged |
| StikDebug URL activation (`stikdebug://enable-jit`) | Implemented, includes bundle ID + PID, and `universal.js` only when TXM is reported present |
| Wait for Debugger | Implemented: polls `CS_DEBUGGED`, then verifies |
| In-process JIT verification (`mov w0, #42; ret`) | Implemented for iOS < 26, where debugger attachment alone enables JIT |
| iOS 26 universal breakpoint protocol (`JIT26PrepareRegion`, `JIT26Detach`) | Implemented in C from the StikJIT documentation, but not exercised: no script is attached here |
| JIT arena (`MAP_JIT`, bump allocator, W^X sealing) | Implemented |
| Built-in StikJIT (embedded `StikJIT.xcframework` in a helper extension) | **Not included in this build** |
| Developer Disk Image download and mount | **Not included**: that work happens inside StikJIT's helper extension |
| On-device pairing record creation | **Not possible from Vortex**: pairing is a host-side exchange; StikDebug performs it |

## Why Built-in StikJIT is not embedded here

StikJIT ships as `StikJIT.xcframework` (release 2.0.1, `StikJIT.xcframework.zip`).
The integration guide requires it to be linked and embedded **in a helper app
extension**, never in the host app, and gives the helper the host PID, pairing
data and settings over XPC. This project's toolchain can add widget, keyboard,
iMessage, share, notification-service and broadcast-upload extensions, but not a
general-purpose app extension target, and it cannot unpack a binary XCFramework
from a zip into the project. Adding it requires Xcode on a Mac.

Everything the guide requires *outside* the framework is implemented, so
dropping the framework into a helper extension later is the remaining step:
`JITCoordinator` already gates every entry point on iOS 17.4, get-task-allow and
a readable pairing file, keeps one serial code path, and never falls through to
another method after a failure.

## Device requirements

1. iOS 17.4 or later (this build's deployment target is 26.0).
2. Vortex installed with `get-task-allow`. That means a development or
   sideloaded build; App Store and TestFlight builds strip it.
3. Developer Mode enabled: Settings › Privacy & Security › Developer Mode.
4. A pairing file from StikDebug (iOS 27 on-device pairing), iloader, or another
   pairing tool, imported into Vortex or placed at
   `Documents/StikJIT/pairingFile.plist` through Finder file sharing.
5. LocalDevVPN connected, ideally on Wi-Fi. Vortex verifies the endpoint
   `10.7.0.1:49152` before reporting the tunnel as connected.

## Switching method

`JITCoordinator.method` is persisted in `UserDefaults` under `vortex.jit.method`.
Only the selected method runs. A failure is reported and left visible; it never
silently switches to another method.

## Distribution

`get-task-allow` and the Security framework's SecTask SPI are incompatible with
App Store distribution, and StikDebug's own JIT is unavailable there. Vortex's
JIT features are therefore limited to development-signed and sideloaded builds.
No Apple security protection is bypassed: JIT is obtained through the debugger
mechanism Apple documents for development, exactly as StikDebug and StikJIT do.

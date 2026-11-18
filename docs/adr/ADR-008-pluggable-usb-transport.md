# ADR-008: Pluggable USB transport

**Status:** Accepted; consumer path pending (Sprint 4, prioritized)

## Context
USB-C is the primary connection. `adb reverse` gives an excellent dev path (~3.5 ms RTT, 90 fps) but requires developer mode.

## Decision
Sprint 1: `--usb` auto-configures `adb reverse` and launches the app on plug-in. Sprint 4: Android Open Accessory (or USB networking) for a consumer path with no developer mode, carrying the same framed protocol.

## Consequences
AOA needs a host-side USB stack on macOS (IOKit/libusb) and the accessory handshake; validate per tablet vendor.

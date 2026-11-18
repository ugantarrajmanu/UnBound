# ADR-001: Native Swift macOS host

**Status:** Accepted

## Context
The host needs direct access to CGVirtualDisplay, ScreenCaptureKit, VideoToolbox and CGEvent, with control over threads and memory.

## Decision
Swift 6 (strict concurrency) for the host. Sprint 1 ships as a CLI (`unbound-host`); the SwiftUI menu-bar app wraps the same `UnboundHostCore` library in Sprint 5.

## Consequences
No Electron/Flutter/React Native in the media path. A C/ObjC shim is used only where private API needs runtime resolution.

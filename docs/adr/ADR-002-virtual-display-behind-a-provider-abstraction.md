# ADR-002: Virtual display behind a provider abstraction

**Status:** Accepted — feasibility gate passed (Apple Silicon)

## Context
Creating a real extended desktop needs the undocumented CGVirtualDisplay API. Apple can change it in any release.

## Decision
`VirtualDisplayProvider` protocol with `PrivateCGVirtualDisplayProvider` and `UnsupportedProvider`. The ObjC shim resolves every private class/selector with `NSClassFromString`/`respondsToSelector`, so a missing API reports *unsupported* instead of crashing at load. `unbound-host probe` is the gate test, verified out-of-process via ScreenCaptureKit.

## Consequences
Re-run `probe` on every macOS beta. Findings (macOS 27): two displays with the same vendor/product/serial cannot coexist; macOS picks its own default mode (so `DisplayModeManager` selects ours); the creating process's CoreGraphics display list can be stale after the first create/destroy (ScreenCaptureKit is the source of truth).

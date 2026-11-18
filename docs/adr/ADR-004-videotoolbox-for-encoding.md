# ADR-004: VideoToolbox for encoding

**Status:** Accepted

## Context
Real-time, low-latency hardware encode on all supported Macs.

## Decision
H.264 High, no B-frames, real-time, `EnableLowLatencyRateControl` (selects Apple's `rtvc` encoder; falls back to the standard hardware encoder). Encoder ID is reported because `rtvc` does not answer the hardware-acceleration query. HEVC is optional later.

## Consequences
Capabilities must be queried at runtime (`unbound-host capabilities`), especially on Intel.

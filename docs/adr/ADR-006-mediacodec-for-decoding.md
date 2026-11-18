# ADR-006: MediaCodec for decoding

**Status:** Accepted

## Context
Hardware decode straight to the display surface.

## Decision
Async MediaCodec on a dedicated HandlerThread rendering to a SurfaceView; `KEY_LOW_LATENCY` when the codec advertises it, plus vendor hints; requests the panel's highest refresh rate and `Surface.setFrameRate`.

## Consequences
Verified on Galaxy Tab S10 FE (Exynos `c2.exynos.h264.decoder`, low-latency, ~15–18 ms).

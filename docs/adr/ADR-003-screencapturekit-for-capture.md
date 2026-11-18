# ADR-003: ScreenCaptureKit for capture

**Status:** Accepted

## Context
Capture must target only the virtual display, efficiently, with the system permission model.

## Decision
`SCStream` with an `SCContentFilter` for the virtual display, NV12 output (native encoder input), queue depth 5, cursor composited.

## Consequences
Frames arrive only when content changes; an idle desktop yields few frames, so new clients get a re-encoded last frame. Requires Screen Recording permission.

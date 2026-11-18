# ADR-005: Native Kotlin Android client

**Status:** Accepted

## Context
The client needs MediaCodec, Surface, USB and input APIs with tight latency control.

## Decision
Kotlin, AndroidX core/activity, programmatic Views (no Compose in the hot path), minSdk 26.

## Consequences
UI polish can adopt Compose later without touching the media pipeline.

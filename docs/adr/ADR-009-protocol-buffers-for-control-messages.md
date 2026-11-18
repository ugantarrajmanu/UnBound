# ADR-009: Protocol Buffers for control messages

**Status:** Proposed (Sprint 2)

## Context
Sprint 1 uses a hand-written binary framing (docs/protocol.md) to keep the media path simple.

## Decision
Move control/input/negotiation to versioned protobuf messages; keep raw access units for video.

## Consequences
The 20-byte header stays as the outer frame for the USB transport.

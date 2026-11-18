# ADR-007: WebRTC for Wi-Fi streaming

**Status:** Proposed (Sprint 2)

## Context
TCP has head-of-line blocking and no real congestion control; Sprint 1 adds a simple AIMD bitrate controller as a stopgap.

## Decision
Adopt WebRTC behind the existing `MediaTransport` protocol for encryption, congestion control and NAT handling.

## Consequences
Encoder, decoder and session code must not change when the transport does.

# Wire protocol v1 (Sprint 1)

Interim framing over a reliable byte stream (TCP; over USB via `adb reverse`).
Sprint 2 moves control messages to Protocol Buffers (ADR-009) and media to WebRTC (ADR-007).
Reference implementations: `mac/Sources/UnboundHostCore/Protocol/WireProtocol.swift`,
`android/app/src/main/java/app/unbound/client/net/WireProtocol.kt`. Both test suites pin the byte layouts.

## Header (20 bytes, big-endian)

| Offset | Type | Field |
|---|---|---|
| 0 | u16 | magic `0x5542` ("UB") |
| 2 | u8 | protocol version = 1 (mismatch → disconnect) |
| 3 | u8 | message type |
| 4 | u8 | flags — bit 0: keyframe |
| 5 | u8[3] | reserved, 0 |
| 8 | u32 | payload length (≤ 16 MiB) |
| 12 | i64 | timestamp µs — video PTS, or sender clock for ping/pong |

## Messages

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | HELLO | host → client | u16 version, UTF-8 host name |
| 0x01 | HELLO | client → host | u16 version, u16 width px, u16 height px, u16 dpi, UTF-8 model |
| 0x02 | CODEC_CONFIG | host → client | u8 codec (1 = H.264), u16 width, u16 height, u16 len + SPS, u16 len + PPS (raw NAL units, no start codes) |
| 0x03 | VIDEO_FRAME | host → client | one access unit, Annex-B; flag bit 0 on IDR |
| 0x04 | REQUEST_KEYFRAME | client → host | — |
| 0x05 | PING | client → host | — (timestamp = client clock) |
| 0x06 | PONG | host → client | — (timestamp echoed) |
| 0x07 | GOODBYE | either | — |
| 0x08 | POINTER | client → host | u8 action (0 down, 1 move, 2 up, 3 cancel), u8 button (0 left, 1 right), u16 0, f32 x, f32 y (0…1 over the video) |
| 0x09 | SCROLL | client → host | f32 dx, f32 dy — video pixels, finger direction |
| 0x0A | KEY | client → host | u8 down, u8 modifiers (1 shift, 2 ctrl, 4 option, 8 command, 16 caps), u16 macOS virtual key code |

## Session rules

- On connect the host sends HELLO, the last CODEC_CONFIG (if any), then an IDR (re-encoding the
  last frame so an idle desktop still produces a picture).
- CODEC_CONFIG precedes every IDR; clients ignore identical configs.
- Congestion: if more than ~1.5 MB is queued, the host drops frames (keyframes included), waits for the
  queue to drain to half, requests one IDR and resumes. Adaptive bitrate (×0.7 on congestion, ×1.15
  after 3 s clear) runs on top. Forced IDRs are spaced ≥ 500 ms apart; extra requests are deferred, never dropped.
- The client drops delta frames until it has decoded an IDR, and asks for one when its decoder backlog exceeds 6 frames.

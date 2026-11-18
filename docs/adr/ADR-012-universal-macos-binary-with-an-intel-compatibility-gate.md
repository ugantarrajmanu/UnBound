# ADR-012: Universal macOS binary with an Intel compatibility gate

**Status:** Accepted — Intel unvalidated

## Context
Universal compilation is not hardware compatibility.

## Decision
Ship arm64 + x86_64 (`swift build -c release --arch arm64 --arch x86_64`). Do not advertise Intel support until `probe` and `capabilities` pass on Intel hardware.

## Consequences
No Intel Mac has been tested yet.

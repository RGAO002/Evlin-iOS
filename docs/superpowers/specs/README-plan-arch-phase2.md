# Plan-arch Phase 2 — iOS pointer

The canonical Phase 2 spec lives in the backend repo:

```
/Users/fred/Desktop/Evlin/Evlin-Backend/docs/superpowers/specs/2026-05-08-plan-arch-phase2-design.md
```

iOS-relevant sections:

- **§3.6** — `CardPayload.kind` catalog (which kinds the iOS adapter must
  handle and which existing card view they map to).
- **§3.8** — `CardPatchPayload` constraint (no intent/family change).
- **§6** — CardFactory + `PlanArchCardAdapter` design, including
  `source` field semantics (`plan` / `event` / `query` decides button
  routing).
- **§7.2** — Event polling cadence + the four optimizations
  (visible-only / background pause / empty backoff / event reset).
- **§9** — Test layers; iOS test files split (six XCTest files).
- **§10.1 – §10.4** — iOS file deltas per sub-phase.

## TestFlight prerequisite

Phase 2A explicitly requires TestFlight to be unblocked before iOS adapter
work begins. Without real-device validation, the visual diff against
phase 1 (`PlanArchCardView` vs polished cards) cannot be verified.

## Two repos, one spec

Don't fork this spec. If iOS-side decisions evolve, edit the canonical
file in the backend repo and update this pointer if section anchors move.

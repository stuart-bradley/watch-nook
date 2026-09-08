# ADR-9: Two backend enums, one concept, one provider

**Status:** accepted · 2026-09-08

> **Where ADR-1…ADR-8 live.** They are a numbered list in
> [`docs/PRD.md`](../PRD.md), written before this directory existed, and the
> citations throughout the code (`ADR-2`, `ADR-4`, `ADR-7`, …) resolve to that
> numbering. They stay there; splitting them into files would change what every
> citation points at and add nothing. This directory starts at **9** so the two
> sequences are one sequence and no number is ever ambiguous.

## Context

Two enums name the metadata backend:

- `MetadataBackend` (`lib/core/config/remote_config.dart`) — what the hosted
  config file says the app should be running against (ADR-2).
- `MetadataSourceKind` (`lib/core/database/tables.dart`) — what a stored row
  was recorded against, and the cache's partition key.

They have the same two values, and a converter maps one to the other. Found
cold, that reads like an accident somebody should tidy up.

It also *had* become one, in a specific way. The converter was wrapped in a
derived provider, `activeMetadataKindProvider`, so "which backend are we on?"
had **two** overridable answers: the config-level provider and the derived one.
Roughly twenty test harnesses overrode the first and three the second. A harness
that overrode only one got a split-brain — rows cached under one backend and
compared against another — which is exactly the drift the derived provider was
introduced to prevent, reintroduced one layer down as a second injection point.

## Decision

**One provider.** `activeMetadataBackendProvider` is the single overridable
answer. The derived provider is gone, replaced by a plain function
`metadataSourceKindOf(MetadataBackend)` in `metadata_providers.dart`. A function
cannot be overridden, which is the property being bought: the single-definition
benefit stays, the second injection point cannot come back.

**Two types.** The enums stay separate. Collapsing them would force one of:

- the database layer imports remote configuration, so persistence depends on
  what a hosted JSON file happens to say; or
- configuration imports persistence, so the config parser depends on the Drift
  schema.

Both trade a real layering rule for a cosmetic win. The operational hazard was
never the duplicate *type* — it was the duplicate *provider*, and that is what
this removes.

## Consequences

- Every harness injects the backend in one place. Overriding it wrongly is now
  a thing you cannot do halfway.
- Call sites read `metadataSourceKindOf(ref.watch(activeMetadataBackendProvider))`
  rather than watching a second provider — longer, and honest about where the
  answer comes from.
- Removing the provider was itself load-bearing evidence: one harness had been
  overriding *both*, and only collapsing them surfaced it as a duplicate.
- A future reader who wants to merge the two enums should read this first. The
  argument against is the layering rule, not the duplication.

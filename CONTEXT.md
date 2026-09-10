# Context: Watch Nook

The vocabulary this codebase uses for a **library row** — one tracked title in
`LibraryItems`. Glossary only: terms and what they mean, no implementation
detail. Architecture decisions are ADR-1…ADR-8 in [`docs/PRD.md`](docs/PRD.md)
and ADR-9 onwards in [`docs/adr/`](docs/adr/).

## The two axes

A library row sits on **two independent axes**. They are not two ends of one
enumeration and must never be modelled as one: a row can be Stranded *and*
Unverified, or perfectly fetchable *and* Unverified, and every combination
occurs in practice.

| | Axis 1 — can we fetch? | Axis 2 — do we trust the position? |
|---|---|---|
| Asks | Do this row's ids mean anything to the active backend? | Does the stored `(season, episode)` still name the episode the user watched? |
| Decided by | `recordedSource` + which id columns are filled | the `relinkFailed` column |
| Values | Stranded / Unlinked / **fetchable** | **Unverified** / trusted |

## Axis 1 — reachability

**Active backend.** The metadata backend the app is running against right now,
set by the hosted config (ADR-2). An operator can flip it between one launch
and the next; the user is never asked.

**Stranded.** A row recorded against a backend that is *not* the active one. Its
ids belong to the other catalogue, where they name a different title, so
nothing may fetch for it. A relink from Settings repairs it.

**Unlinked.** A row on the active backend that carries no id for it — an
offline add, or an import matched on title alone. Nothing may fetch for it
either, but a relink cannot help. Searching for the title opens this same row
untouched; only a re-import that matches it can fill the id in.

**Fetchable.** Neither of the above: the row is on the active backend and
carries its id. The ordinary case.

Stranded and Unlinked are the two reasons a title is *unfetchable*. They render
identically — the stored row alone, no network — and are kept distinct because
their fixes differ.

## Axis 2 — trust in the position

**Position.** Where the user is in a show: the stored `(lastWatchedSeason,
lastWatchedEpisode)` coordinate, plus whatever is derived from it (the grid
caption, the Up Next "next episode"). A movie has no position.

**Unverified.** The app could not confirm that a title's watched coordinates
still name the same episodes after a backend switch — an episode has no
counterpart on the new backend, the air-dates disagree, or the title has
watched specials, which never map across backends. It is set by the relink and
means, exactly:

> **The count is right, the position may not be.** A human should look.

What Unverified does **not** mean:

- It does not block fetching. It says nothing about axis 1 and never influences
  the reference the app fetches with, the artwork it shows, or whether the
  title is Stranded.
- It does not mean watch history was modified. A backend switch never touches
  `WatchEvents`; totals, hours and counts are historically accurate and the
  stats screen says nothing about this state.
- It is not a transient error. Re-running the same comparison against the same
  data fails the same way, which is why there is no "re-check" — only a human
  checking the episode list and dismissing the marker.

**"Unconfirmed" in the UI.** The user never sees the word Unverified: the marker
reads "(unconfirmed)" and the detail notice says the position "is unconfirmed".
The split is deliberate, because "unverified" reads as jargon to a user. Keep
**Unverified** in code and in this glossary, and do not "fix" the UI to match.

**Dismissed.** A user has looked at the episode list and confirmed the position
is right, clearing the flag for that one row. There is no bulk dismiss. The
cleared state is part of the exported backup, so it survives an export and
re-import — and, symmetrically, restoring a pre-dismiss backup brings the
marker back.

A dismissal is **not permanent for a Stranded row.** The dismiss clears the same
column the relink writes, and a row still on the other backend is re-tried by
every later relink — so if that attempt fails again, the marker returns. This is
the lesser of two evils and deliberate: the alternative is a second column whose
only job is to suppress a warning, and a row that stops being offered for relink
because a user once said its position looked right. For the row this feature is
really about — relinked, episodes did not reconcile — no later run touches it,
so a dismissal there is final. The detail screen only offers the dismiss when
the episode list is on screen, which a Stranded row's never is.

## How the two interact on a relink

The relink writes the same flag for two different outcomes, and they behave
differently afterwards:

| Outcome | Recorded source after | Unverified | Still Stranded? | Retried by a later relink? |
|---|---|---|---|---|
| Could not relink at all | left on the **other** backend | yes | yes | **yes** — still counted by the Settings relink offer |
| Relinked, episodes did not reconcile | the **active** backend | yes | no — it fetches happily | **no** — later runs skip it |

The second row is the dangerous one: it looks completely healthy. It is the
reason the marker exists, and the only thing that clears it is a dismiss.

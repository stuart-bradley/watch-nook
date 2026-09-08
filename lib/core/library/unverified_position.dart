/// **The marker for an Unverified position** — the rule and its wording, in one
/// pure place. No widgets, no providers.
///
/// A backend switch relinks each library row to the new catalogue and checks,
/// for a show, that every watched `(season, episode)` still names the same
/// episode by comparing air-dates. When that check cannot be made to pass the
/// row is left **Unverified** (CONTEXT.md, axis 2), meaning exactly:
///
/// > The count is right, the position may not be. A human should look.
///
/// Three surfaces render a position — the grid caption, the Up Next episode
/// label, and the detail screen — and all three take the marker from here.
/// Marking at each site independently would be three copies of one rule, free
/// to drift in wording; this repo has already been bitten by a rule documented
/// in one file and violated in the next one written the same day.
///
/// **This says nothing about axis 1.** Unverified never influences the
/// reference the app fetches with, never suppresses artwork, and never appears
/// in `DetailTarget` — that type answers fetchability only. A row can be
/// Unverified and perfectly fetchable, which is precisely the dangerous case.
library;

import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

/// What the marker reads as, appended to a rendered position.
///
/// Words, not a bare glyph: this is the only cue the user gets that the app
/// cannot vouch for where they are in a show, and a screen reader must be able
/// to say it.
const _marker = '(unconfirmed)';

/// Whether [item]'s **position** carries the marker.
///
/// Three things must hold, and each rules out a title there is no reason to
/// doubt:
///
/// - the row is Unverified — nothing else is in question;
/// - it is a show — a movie has no `(season, episode)` coordinate to be wrong
///   about, so there is nothing for the marker to qualify;
/// - a position exists — an Unverified show with nothing watched displays no
///   coordinate, and warning about a position that is not on screen tells the
///   user to check something they cannot see.
bool hasUnverifiedPosition(LibraryItem item) =>
    item.relinkFailed &&
    item.mediaType == MediaType.tv &&
    item.lastWatchedSeason != null &&
    item.lastWatchedEpisode != null;

/// The detail screen's fuller statement of the same marker — the one surface
/// with room for a sentence, and the only one where the user can act on it.
///
/// It says three things, all of them load-bearing: which fact is in doubt (the
/// position, not the title), that the history itself is intact, and what the
/// user is being asked to do. Without the second, "unconfirmed" reads as
/// "your watch history may be damaged", which is the opposite of true.
const unverifiedPositionNotice =
    'Where you are in this show is unconfirmed. A catalogue change meant we '
    "couldn't check that your watched episodes still line up. Nothing was "
    'changed — your history and totals are exactly as they were. Check the '
    'seasons below, then dismiss this.';

/// What the dismiss action reads as, on the detail screen.
const unverifiedPositionDismissLabel = 'Looks right';

/// [position] with the marker appended when [unverified], unchanged otherwise.
///
/// Takes the already-rendered position rather than the row, because the two
/// label builders render different positions ("where you are" vs "what is
/// next") and neither is the other's business. What they share is the marker,
/// which is all this owns.
String markUnverifiedPosition(String position, {required bool unverified}) =>
    unverified ? '$position $_marker' : position;

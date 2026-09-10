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
/// Three surfaces render a position — the grid caption, the Up Next watch-queue
/// label, and the detail screen — and all three take the marker from here. An
/// Up Next *upcoming* row is not one of them: its coordinate is the backend's
/// next-to-air episode, not derived from the position (see `UpcomingEntry`).
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

/// How every detail-screen notice begins: the fuller statement of the marker,
/// on the one surface with room for a sentence.
///
/// It says two load-bearing things: which fact is in doubt (the position, not
/// the title), and that the history itself is intact. Without the second,
/// "unconfirmed" reads as "your watch history may be damaged", which is the
/// opposite of true. The third thing, what to do, depends on why the episode
/// list is or isn't on screen, so each variant below closes with its own.
///
/// "Metadata provider" is the Settings relink offer's name for this event. Two
/// names for one event make a user think two different things happened.
const unverifiedPositionNoticeOpening =
    'Where you are in this show is unconfirmed. After a switch of metadata '
    "provider, we couldn't match your watched episodes to the new episode "
    "list. Your history and totals haven't changed.";

/// The notice when the episode list **is** on screen: the evidence is right
/// there, so the user can check it and dismiss with
/// [unverifiedPositionDismissLabel].
const unverifiedPositionNoticeListShown =
    '$unverifiedPositionNoticeOpening Check the seasons below.';

/// The notice for a **Stranded** row: its ids belong to the other backend, so
/// nothing can be fetched for it and the list will never appear until a relink.
/// No dismiss: the user would be confirming a position against evidence the
/// screen cannot show.
const unverifiedPositionNoticeStranded =
    "$unverifiedPositionNoticeOpening Its episode list can't load until you "
    'relink your library in Settings.';

/// The notice for a **fetchable** row whose list simply hasn't loaded (offline,
/// or the new backend's cache still cold straight after a switch).
///
/// It must not mention Settings. A relink skips any row already on the active
/// backend, so sending this user there changes nothing and they come straight
/// back to the same advice. No dismiss, for the same reason as the Stranded
/// variant; the list-shown variant takes over as soon as the list arrives.
///
/// Strictly, this is "fetchable, but no seasons on screen", so it also covers
/// details that loaded with no seasons at all. A show the user has a stored
/// position in should not reach that, so the copy assumes the common cause.
const unverifiedPositionNoticeNotLoaded =
    "$unverifiedPositionNoticeOpening Its episode list hasn't loaded yet, so "
    'check back once it has.';

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

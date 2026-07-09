import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/tv_time_importer.dart';

/// #24 — the TV Time importer, against the **real** curated GDPR export.
///
/// Adversarial angles, each a regression someone would otherwise ship:
/// - the export is CSV with quoted commas and unicode, so a naive `split(',')`
///   forks `"Love, Death & Robots"` into two dead columns;
/// - `seen_episode_latest.csv` is a *delta*; treating it as the episode table
///   silently discards ~300 watched episodes;
/// - every movie appears **twice** (a `follow` row and a `watch` row) under one
///   uuid, so collapsing on title-or-nothing doubles the library;
/// - a real `0001-01-01` release date must not become "year 1";
/// - `tv_show_id = N/A` and a truncated final row must cost a row, not throw a
///   `TypeError` past `on Exception` (CLAUDE.md).

ImportArchive _fixture(String dir) {
  final root = Directory(dir);
  return ImportArchive({
    for (final file in root.listSync().whereType<File>())
      file.uri.pathSegments.last: Uint8List.fromList(file.readAsBytesSync()),
  });
}

ImportRecord _byTitle(ParseResult parsed, String title) =>
    parsed.records.firstWhere((r) => r.title == title);

void main() {
  late ParseResult parsed;

  setUpAll(
    () => parsed = TvTimeImporter.parse(_fixture('test/fixtures/tvtime')),
  );

  test('recognises its own archive, and not a Letterboxd one', () {
    expect(TvTimeImporter.canRead(_fixture('test/fixtures/tvtime')), isTrue);
    expect(
      TvTimeImporter.canRead(_fixture('test/fixtures/letterboxd')),
      isFalse,
    );
  });

  test(
    'the real export parses whole: 23 shows + 10 movies, nothing skipped',
    () {
      expect(parsed.skippedRows, 0);
      expect(
        parsed.records.where((r) => r.mediaType == MediaType.tv),
        hasLength(23),
      );
      expect(
        parsed.records.where((r) => r.mediaType == MediaType.movie),
        hasLength(10),
        reason:
            '20 tracking rows (follow + watch) collapse to 10 films by uuid',
      );
    },
  );

  test('RFC-4180 quoting survives: a comma inside a title is not a column', () {
    // The title is the join key across the export's tables, so a split-on-comma
    // parser loses the id (column shifts by one) *and* the cross-file join.
    final show = _byTitle(parsed, 'Love, Death & Robots');
    expect(show.tvdbId, 357888, reason: 'from followed_tv_show.csv');
    expect(
      show.trackStatus,
      TrackStatus.dropped,
      reason: 'is_followed=0, joined from user_tv_show_data.csv by title',
    );
  });

  test('unicode titles are carried verbatim', () {
    expect(_byTitle(parsed, 'Shōgun').tvdbId, 392573);
  });

  test('a parenthetical year becomes the year, and stays in the title', () {
    expect(_byTitle(parsed, 'ONE PIECE (2023)').year, 2023);
    expect(_byTitle(parsed, 'Battlestar Galactica (2003)').year, 2003);
    expect(_byTitle(parsed, 'Chernobyl').year, isNull);
  });

  test('seen_episode_latest is a delta, unioned onto seen_episode_source', () {
    final episodes = parsed.records
        .where((r) => r.mediaType == MediaType.tv)
        .expand((r) => r.watches);
    expect(episodes, hasLength(312), reason: '306 source + 6 latest, disjoint');

    // The delta's rows, and only the delta's, carry these coordinates.
    final boys = _byTitle(parsed, 'The Boys').watches;
    expect(boys.any((w) => w.season == 5 && w.episode == 7), isTrue);
    expect(boys.every((w) => !w.isRewatch), isTrue);
  });

  test('a watched episode keeps its date', () {
    final watch = _byTitle(parsed, 'The Big Bang Theory').watches.firstWhere(
      (w) => w.season == 1 && w.episode == 1,
    );
    expect(watch.watchedAt, DateTime.parse('2019-04-26 13:23:11'));
  });

  test('archived means completed; unfollowed-and-unarchived means dropped', () {
    expect(
      _byTitle(parsed, 'Doctor Who (2005)').trackStatus,
      TrackStatus.completed,
    );
    expect(_byTitle(parsed, 'Good Omens').trackStatus, TrackStatus.dropped);
    expect(
      _byTitle(parsed, 'Love, Death & Robots').trackStatus,
      TrackStatus.dropped,
    );
    expect(_byTitle(parsed, 'The Bear').trackStatus, TrackStatus.watching);
  });

  test('a watched movie is completed with exactly one first-watch', () {
    final movie = _byTitle(parsed, 'The Social Network');
    expect(movie.mediaType, MediaType.movie);
    expect(movie.year, 2010);
    expect(movie.trackStatus, TrackStatus.completed);
    expect(movie.watches, hasLength(1));
    expect(movie.watches.single.season, isNull);
    expect(movie.watches.single.isRewatch, isFalse);
    expect(movie.tvdbId, isNull, reason: 'TV Time movies carry only a uuid');
  });

  test('a 0001-01-01 release date is a sentinel, not year 1', () {
    // The `watch` row says 0001-01-01; the `follow` row for the same uuid
    // carries the real date, and the merge must prefer it.
    expect(_byTitle(parsed, 'Avengers: Endgame').year, 2019);
  });

  test('follow without watch is a watchlist entry, with no watch events', () {
    final only = TvTimeImporter.parse(
      _archiveOf({TvTimeImporter.trackingFile: _trackingCsv(watched: false)}),
    );
    final movie = only.records.single;
    expect(movie.trackStatus, TrackStatus.watchlist);
    expect(movie.watches, isEmpty);
  });

  test('rewatch_count appends rewatches on top of the first watch', () {
    final parsed = TvTimeImporter.parse(
      _archiveOf({
        TvTimeImporter.trackingFile: _trackingCsv(
          watched: true,
          rewatchCount: 2,
        ),
      }),
    );
    final movie = parsed.records.single;
    expect(movie.watches.where((w) => !w.isRewatch), hasLength(1));
    expect(movie.watches.where((w) => w.isRewatch), hasLength(2));
  });

  test('malformed rows are skipped and counted, never thrown', () {
    final parsed = TvTimeImporter.parse(
      _archiveOf({
        TvTimeImporter.followedFile: File(
          'test/fixtures/malformed/tvtime_followed_tv_show.csv',
        ).readAsStringSync(),
      }),
    );

    expect(parsed.records, hasLength(1), reason: 'only the well-formed row');
    expect(parsed.records.single.title, 'Arrested Development');
    expect(
      parsed.skippedRows,
      2,
      reason: 'tv_show_id = N/A, plus the truncated final row',
    );
  });

  test(
    'an orphan episode row is counted, never filed under an invented show',
    () {
      final parsed = TvTimeImporter.parse(
        _archiveOf({
          TvTimeImporter.seenSourceFile:
              'episode_number,tv_show_name,episode_season_number,created_at\n'
              '1,Never Followed,1,2020-01-01 00:00:00\n',
        }),
      );
      expect(parsed.records, isEmpty);
      expect(parsed.skippedRows, 1);
    },
  );

  test('an absent table is not an error', () {
    final parsed = TvTimeImporter.parse(_archiveOf(const {}));
    expect(parsed.records, isEmpty);
    expect(parsed.skippedRows, 0);
  });
}

ImportArchive _archiveOf(Map<String, String> files) => ImportArchive({
  for (final entry in files.entries)
    entry.key: Uint8List.fromList(utf8.encode(entry.value)),
});

/// The tracking columns this importer reads, in the real export's shape: one
/// `follow` row and (optionally) one `watch` row, sharing a uuid.
String _trackingCsv({required bool watched, int rewatchCount = 0}) {
  const uuid = '00933248-92a9-47df-b5a8-5f95852ad76a';
  const released = '2021-10-20 00:00:00';
  final rows = <List<String>>[
    [
      'type',
      'uuid',
      'created_at',
      'movie_name',
      'release_date',
      'entity_type',
      'rewatch_count',
      'watch_date',
    ],
    [
      'follow',
      uuid,
      '2026-01-01 14:56:19',
      'Wolfwalkers',
      released,
      'movie',
      '',
      '',
    ],
    if (watched)
      [
        'watch',
        uuid,
        '2026-01-01 14:56:22',
        'Wolfwalkers',
        released,
        'movie',
        '$rewatchCount',
        '',
      ],
  ];
  return rows.map((r) => r.join(',')).join('\n');
}

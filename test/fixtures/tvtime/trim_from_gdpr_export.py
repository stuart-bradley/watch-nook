#!/usr/bin/env python3
"""Regenerate the curated TV Time fixtures from a raw GDPR export.

Reads straight from the export zip (no extraction), filters to a curated
whitelist with the stdlib csv module (correct quoting), scrubs the real
user_id, and writes the 5 import-relevant CSVs into this directory.

The raw TV Time GDPR export is irreplaceable (TV Time shut down 2026-07-15),
so this script is the record of *which* rows were kept and how PII was removed.
Point ZIP at a fresh/full export to re-trim.

    python3 test/fixtures/tvtime/trim_from_gdpr_export.py [path/to/gdpr-data.zip]

PII: only these 5 tables are emitted; every other GDPR table (email, IP,
tokens, connections, notifications, device/ad ids, multi-MB tracking dumps)
is dropped. The real user_id is replaced with a fixed dummy.
"""
import csv, io, os, sys, zipfile

ZIP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads/gdpr-data.zip")
OUT = os.path.dirname(os.path.abspath(__file__))
DUMMY_UID = "10000000"
REAL_UID = ""  # discovered from the export at runtime so this script never embeds a real account id

# Curated shows: core-tracked + every show that carries real watched history,
# plus edge cases (quoted-comma names, year-disambig, unicode, aired-order).
SHOWS = {
    "Arrested Development", "QI", "The Office (US)", "Battlestar Galactica (2003)",
    "Band of Brothers", "Avatar: The Last Airbender", "The Big Bang Theory",
    "Breaking Bad", "Doctor Who (2005)", "Marvel's Agents of S.H.I.E.L.D.",
    "Orange Is the New Black", "The Magicians (2015)", "Warrior", "Chernobyl",
    "Good Omens", "What We Do in the Shadows", "The Boys", "ONE PIECE (2023)",
    "Shōgun", "House of the Dragon", "The Bear",
    "Love, Death & Robots", "Seven Worlds, One Planet",
}
# Curated movies (keep ALL their rows -> preserves real duplicate-row + bogus-date edges).
# The first four are the plan's named fuzzy-match anchors; Avengers: Endgame carries the
# real bogus `0001-01-01` release-date edge. No title here appears in any source's watchlist
# (watchlisted films must not also be TV-Time-watched, or MergeApplier sees a false conflict).
MOVIES = {
    "The Social Network", "Encanto", "Wolfwalkers", "Finding Dory",
    "Black Panther", "Avengers: Endgame", "Baby Driver", "Coraline",
    "District 9", "Children of Men",
}


def scrub(row):
    # global replace covers the user_id column and any field that embeds it
    return [c.replace(REAL_UID, DUMMY_UID) if REAL_UID else c for c in row]


def read(zf, name):
    with zf.open(name) as fh:
        return list(csv.reader(io.TextIOWrapper(fh, encoding="utf-8")))


def write(name, header, rows):
    with open(os.path.join(OUT, name), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(scrub(header))
        for r in rows:
            w.writerow(scrub(r))
    print(f"  {name}: {len(rows)} rows")


def filtered(zf, name, keep):
    header, *body = read(zf, name)
    col = {c: i for i, c in enumerate(header)}
    return header, [r for r in body if keep(r, col)]


with zipfile.ZipFile(ZIP) as zf:
    # discover the real user_id from the export (the user_id column) — never hardcoded
    _h, *_body = read(zf, "followed_tv_show.csv")
    REAL_UID = _body[0][_h.index("user_id")]

    write("followed_tv_show.csv",
          *filtered(zf, "followed_tv_show.csv", lambda r, c: r[c["tv_show_name"]] in SHOWS))
    # recent-watch snapshot -> keep only rows for curated shows (no orphan untracked shows)
    write("seen_episode_latest.csv",
          *filtered(zf, "seen_episode_latest.csv", lambda r, c: r[c["tv_show_name"]] in SHOWS))
    write("seen_episode_source.csv",
          *filtered(zf, "seen_episode_source.csv", lambda r, c: r[c["tv_show_name"]] in SHOWS))
    write("user_tv_show_data.csv",
          *filtered(zf, "user_tv_show_data.csv", lambda r, c: r[c["tv_show_name"]] in SHOWS))

    # movie rows for curated titles + a few episode rows for kept shows
    header, *body = read(zf, "tracking-prod-records.csv")
    c = {name: i for i, name in enumerate(header)}
    movies = [r for r in body if r[c["entity_type"]] == "movie" and r[c["movie_name"]] in MOVIES]
    episodes = [r for r in body if r[c["entity_type"]] == "episode" and r[c["series_name"]] in SHOWS][:15]
    write("tracking-prod-records.csv", header, movies + episodes)

print("done.")

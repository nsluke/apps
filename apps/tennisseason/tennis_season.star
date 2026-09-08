"""
Applet: Tennis Season
Summary: Tennis all year round
Description: Follows the tennis season, not just the scoreboard. During a tournament it rotates live scores, then results, then what is on next. Between tournaments it counts down to the next one, with the host city, surface and defending champion. Optionally follow one player: their live match takes over the screen, and when they are knocked out the app steps aside. Men's, women's or both. Renders on 64x32 and 64x64.
Author: NSLuke
"""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")

BASE = "https://site.api.espn.com/apis/site/v2/sports/tennis/"
CORE = "https://sports.core.api.espn.com/v2/sports/tennis/leagues/atp/events/"

TTL_LIVE = 300

# The slam feeds are small and change every few seconds; the match list and the
# point must come from the same moment or the two halves of the page disagree.
TTL_PBP = 45
TTL_DAY = 3600
TTL_RANK = 43200
TTL_SLAM = 604800

AMBER = "#FFB020"
WHITE = "#FFFFFF"
DIM = "#6E6660"
DIMMER = "#4A4440"
GREEN = "#3FD16B"
SUSPEND = "#5A8FD6"
HARD = "#2E6BA8"
CLAY = "#C2703D"
GRASS = "#4E7A3A"
BLACK = "#000000"
RULE = "#2A2622"
TT = "tom-thumb"

# The Grand Slam sites publish IBM SlamTracker as plain, keyless JSON. During a
# slam it is both richer than the tour scoreboard (point scores, aces, serve
# speed) and ~200x smaller, so it is preferred while it has anything to say.
# It rejects a default user agent with an HTTP/2 stream reset, which Starlark
# cannot catch, so every request below carries a browser UA.
SLAM_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
SLAM_HEADERS = {"User-Agent": SLAM_UA}

# Australian Open and Roland Garros publish elsewhere; until those paths are
# known the app simply stays on the tour scoreboard for them.
# Each entry also carries the months its tournament can run in, so the app does
# not spend two requests a render probing dead feeds for the other ten months.
SLAM_FEEDS = [
    ["https://www.usopen.org/en_US/scores/feeds/", "US OPEN", HARD, [8, 9]],
    ["https://www.wimbledon.com/en_GB/scores/feeds/", "WIMBLEDON", GRASS, [6, 7]],
]

# Wimbledon calls them Gentlemen's and Ladies'; everyone else says Men's and
# Women's. Listing both keeps the juniors, wheelchair and invitation draws out.
SLAM_SINGLES = {
    "Men's Singles": "atp",
    "Gentlemen's Singles": "atp",
    "Women's Singles": "wta",
    "Ladies' Singles": "wta",
}
SLAM_DOUBLES = {
    "Men's Doubles": "atp",
    "Gentlemen's Doubles": "atp",
    "Women's Doubles": "wta",
    "Ladies' Doubles": "wta",
    "Mixed Doubles": "both",
}

SINGLES = {"atp": "mens-singles", "wta": "womens-singles"}
DOUBLES = {"atp": "mens-doubles", "wta": "womens-doubles"}

# Grand slam tournament ids are stable across seasons (verified 2024-2026).
SLAM_ORDER = ["154", "172", "188", "189"]
SLAM_NAME = {"154": "Australian Open", "172": "Roland Garros", "188": "Wimbledon", "189": "US Open"}
SLAM_MONTH = {"154": 1, "172": 5, "188": 6, "189": 8}
SLAM_SURFACE = {"154": HARD, "172": CLAY, "188": GRASS, "189": HARD}
SLAM_SURFACE_NAME = {"154": "HARD", "172": "CLAY", "188": "GRASS", "189": "HARD"}
MONTHS = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]

# ---------------------------------------------------------------- fetching

def get_json(url, ttl, headers = {}):
    """Fetch and decode JSON.

    A transport error inside http.get aborts the whole render with no way to
    catch it, so a marker is written to the cache BEFORE the request. If the
    marker is still 'try' on the next render, the previous attempt never
    returned and we cool off instead of aborting again.
    """
    gate = "tsn.g:" + url
    state = cache.get(gate)
    if state == "try":
        cache.set(gate, "cool", ttl_seconds = 300)
        return None
    if state == "cool":
        return None

    cache.set(gate, "try", ttl_seconds = 600)
    resp = http.get(url = url, ttl_seconds = ttl, headers = headers)
    cache.set(gate, "ok", ttl_seconds = 5)

    if resp.status_code != 200:
        return None
    return json.decode(resp.body(), None)

# ---------------------------------------------------------------- time

def digits(s):
    for c in s.elems():
        if c < "0" or c > "9":
            return False
    return True

def parse_iso(s):
    """ESPN stamps look like 2026-08-24T04:00Z. Shape-check before int().

    time.parse_time aborts on anything it dislikes; time.time normalises
    out-of-range fields instead, so hand-parsing cannot kill the render.
    """
    if type(s) != "string" or len(s) < 16:
        return None
    if not (digits(s[0:4]) and digits(s[5:7]) and digits(s[8:10]) and digits(s[11:13]) and digits(s[14:16])):
        return None
    return time.time(
        year = int(s[0:4]),
        month = int(s[5:7]),
        day = int(s[8:10]),
        hour = int(s[11:13]),
        minute = int(s[14:16]),
        location = "UTC",
    )

def pad2(n):
    return ("0" + str(n))[-2:]

def iso_now(now):
    return "%s-%s-%sT%s:%sZ" % (str(now.year), pad2(now.month), pad2(now.day), pad2(now.hour), pad2(now.minute))

def days_until(target, now):
    return int((target - now).hours // 24)

def countdown_text(target, now):
    d = target - now
    hrs = int(d.hours)
    if hrs < 0:
        return "NOW", ""
    if hrs < 1:
        return str(int(d.minutes)), "MIN"
    if hrs < 48:
        return str(hrs), "HRS"
    return str(hrs // 24), "DAYS"

# ---------------------------------------------------------------- layout

def is_square():
    w, h = canvas.size()
    return h * 2 > w + 16

def bar(left, right, color, ink):
    return render.Box(
        width = 64,
        height = 7,
        color = color,
        child = render.Padding(
            pad = (2, 1, 2, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Text(left, font = TT, color = ink),
                    render.Text(right, font = TT, color = ink),
                ],
            ),
        ),
    )

def line(txt, color, top):
    return render.Padding(pad = (2, top, 1, 0), child = render.Text(txt, font = TT, color = color))

def divider(top):
    return render.Padding(pad = (1, top, 1, 0), child = render.Box(width = 62, height = 1, color = RULE))

def clip(s, n):
    if len(s) <= n:
        return s
    return s[0:n]

def plain(items):
    """Wrap bare strings (kick-off times) as cells with no set winner."""
    return [[t, None] for t in items]

def cell_gap(cells):
    # A five-set match needs all five columns, so the gap tightens rather than
    # the earliest set being dropped.
    return 1 if len(cells) > 3 else 2

def scores_row(cells, color):
    kids = []
    gap = cell_gap(cells)
    first = True
    for cell in cells:
        won = cell[1]
        if won == True:
            ink = WHITE
        elif won == False:
            ink = DIM
        else:
            ink = color
        kids.append(render.Padding(pad = (0 if first else gap, 0, 0, 0), child = render.Text(cell[0], font = TT, color = ink)))
        first = False
    return render.Row(children = kids)

def score_width(cells):
    w = 0
    gap = cell_gap(cells)
    for cell in cells:
        w += 4 * len(cell[0])
    if len(cells) > 1:
        w += gap * (len(cells) - 1)
    return w

def player_row(name, cells, color, serving):
    # Reserve a few pixels so a long surname never runs flush into the scores.
    budget = max(5, (58 - score_width(cells)) // 4)
    return render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text(clip(name, budget), font = TT, color = GREEN if serving else color),
            scores_row(cells, color),
        ],
    )

# ---------------------------------------------------------------- data shaping

def sets_of(competitor):
    """Every set played, each carrying its own winner flag.

    A men's slam match runs to five sets, so nothing is truncated - the set in
    progress has no winner yet and keeps the row colour.
    """
    out = []
    for ls in (competitor.get("linescores") or []):
        v = ls.get("value")
        if v == None:
            continue
        out.append([str(int(v)), ls.get("winner")])
    return out

def serving(competitor):
    return competitor.get("possession") == True

def surname(name):
    """"A. Michelsen" -> "MICHELSEN", "R. Carballes Baena" -> "CARBALLES BAENA"."""
    parts = name.split(" ")
    if len(parts) > 1 and len(parts[0]) <= 2 and parts[0].endswith("."):
        name = " ".join(parts[1:])
    return name.upper()

def short_name(competitor):
    a = competitor.get("athlete") or {}
    return surname(a.get("shortName") or a.get("displayName") or "?")

def guid_of(competitor):
    return (competitor.get("athlete") or {}).get("guid")

def hhmm(iso, tz):
    t = parse_iso(iso)
    if t == None:
        return ""
    local = t.in_location(tz)
    return "%s:%s" % (pad2(local.hour), pad2(local.minute))

def when_text(iso, tz):
    t = parse_iso(iso)
    if t == None:
        return "TIME TBD"
    return t.in_location(tz).format("Mon 15:04").upper()

def match_widget(comp, mode, tz):
    cs = comp.get("competitors") or []
    if len(cs) < 2:
        return None
    a, b = cs[0], cs[1]

    if mode == "sched":
        return render.Column(children = [
            player_row(short_name(a), plain([hhmm(comp.get("date", ""), tz)]), DIM, False),
            player_row(short_name(b), [], DIM, False),
        ])

    if mode == "final":
        ca = AMBER if a.get("winner") else DIMMER
        cb = AMBER if b.get("winner") else DIMMER
        return render.Column(children = [
            player_row(short_name(a), sets_of(a), ca, False),
            player_row(short_name(b), sets_of(b), cb, False),
        ])

    susp = comp.get("wasSuspended") == True
    col = SUSPEND if susp else WHITE
    return render.Column(children = [
        player_row(short_name(a), sets_of(a), col, serving(a)),
        player_row(short_name(b), sets_of(b), col, serving(b)),
    ])

def round_label(comp):
    r = (comp.get("round") or {}).get("displayName") or ""
    if r.startswith("Qualifying"):
        return "Q"
    if r.startswith("Round "):
        return "R" + r[6:]
    if r == "Quarterfinal":
        return "QF"
    if r == "Semifinal":
        return "SF"
    if r == "Final":
        return "F"
    return clip(r.upper(), 3)

def is_qualifying(comp):
    return ((comp.get("round") or {}).get("displayName") or "").startswith("Qualifying")

def wanted_slugs(tours, doubles):
    slugs = []
    for t in tours:
        slugs.append(SINGLES[t])
        if doubles:
            slugs.append(DOUBLES[t])
    return slugs

def competitions(ev, slugs, quals):
    out = []
    for g in (ev.get("groupings") or []):
        if (g.get("grouping") or {}).get("slug") not in slugs:
            continue
        for c in (g.get("competitions") or []):
            if not quals and is_qualifying(c):
                continue
            out.append(c)
    return out

def by_date(c):
    return c.get("date", "")

def state_of(comp):
    return ((comp.get("status") or {}).get("type") or {}).get("state", "")

# ---------------------------------------------------------------- tournament colour

def surface_for(ev, now):
    sid = (ev.get("id") or "").split("-")[0]
    if sid in SLAM_SURFACE:
        return SLAM_SURFACE[sid], SLAM_SURFACE_NAME[sid]

    # The tour's surface swing is seasonal. Colour only - the surface is not
    # in the feed, so the name is claimed only where it is certain.
    m = now.month
    start = parse_iso(ev.get("date", ""))
    if start != None:
        m = start.month
    if m == 4 or m == 5:
        return CLAY, ""
    if m == 6 or m == 7:
        return GRASS, ""
    return HARD, ""

def tour_tag(tours):
    if len(tours) == 1:
        return tours[0].upper()
    return "ATP/WTA"

# ---------------------------------------------------------------- events

def scoreboard(tour, dates):
    url = BASE + tour + "/scoreboard"
    if dates != "":
        url += "?dates=" + dates
    return get_json(url, TTL_LIVE if dates == "" else TTL_DAY)

def gather(tours, slams_only, now_iso):
    """Returns (live tournaments, upcoming tournaments, future calendar days)."""
    running = {}
    ahead = {}
    days = []
    for t in tours:
        d = scoreboard(t, "")
        if d == None:
            continue
        for e in (d.get("events") or []):
            if slams_only and e.get("major") != True:
                continue
            start = e.get("date", "")
            end = e.get("endDate", "")
            if start <= now_iso and now_iso <= end:
                running[e["id"]] = e
            elif start > now_iso:
                ahead[e["id"]] = e
        leagues = d.get("leagues") or []
        if len(leagues) > 0:
            for c in (leagues[0].get("calendar") or []):
                if c > now_iso:
                    days.append(c)
    return running.values(), ahead.values(), sorted(days)

def earliest(events):
    best = None
    for e in events:
        if best == None or e.get("date", "") < best.get("date", ""):
            best = e
    return best

def next_from_calendar(tours, days, slams_only, now_iso):
    """One probe at the next day the tour is actually playing."""
    if len(days) == 0:
        return None
    day = days[0]
    stamp = day[0:4] + day[5:7] + day[8:10]
    for t in tours:
        d = scoreboard(t, stamp)
        if d == None:
            continue
        cands = []
        for e in (d.get("events") or []):
            if slams_only and e.get("major") != True:
                continue
            if e.get("endDate", "") > now_iso:
                cands.append(e)
        best = earliest(cands)
        if best != None:
            return best
    return None

def next_slam(now, now_iso):
    """Slam ids are stable, so ask for the event directly.

    Bounded to three lookups: the season boundary is the only place this
    walks, and ESPN does not publish next season until late in the year.
    """
    tries = []
    for sid in SLAM_ORDER:
        if SLAM_MONTH[sid] >= now.month:
            tries.append([sid, now.year])
    for sid in SLAM_ORDER:
        tries.append([sid, now.year + 1])

    for cand in tries[0:3]:
        ev = get_json(CORE + "%s-%d" % (cand[0], cand[1]), TTL_SLAM)
        if ev == None:
            continue
        if ev.get("date", "") > now_iso:
            return ev, cand[0]
    return None, tries[0][0]

# ---------------------------------------------------------------- panels

def countdown_panel(ev, sid, tours, now, sq):
    name = ev.get("shortName") or ev.get("name") or SLAM_NAME.get(sid, "Tennis")
    start = parse_iso(ev.get("date", ""))
    colour, surface = surface_for(ev, now)
    if sid in SLAM_SURFACE:
        colour, surface = SLAM_SURFACE[sid], SLAM_SURFACE_NAME[sid]

    kids = [bar("NEXT UP", tour_tag(tours), colour, WHITE)]

    if start == None:
        # Next season is not published yet - name the month, claim no date.
        kids.append(render.Padding(pad = (2, 2, 1, 0), child = render.Text(clip(name.upper(), 15), font = TT, color = AMBER)))
        kids.append(line(MONTHS[SLAM_MONTH.get(sid, 1) - 1], WHITE, 1))
        kids.append(line("DATES TBA", DIM, 1))
        return render.Column(children = kids)

    big, unit = countdown_text(start, now)
    kids.append(render.Padding(
        pad = (2, 0, 0, 0),
        child = render.Row(
            cross_align = "end",
            children = [
                render.Text(big, font = "6x13", color = AMBER),
                render.Padding(pad = (2, 0, 0, 2), child = render.Text(unit, font = TT, color = DIM)),
            ],
        ),
    ))
    kids.append(line(clip(name.upper(), 15), WHITE, 0))

    date_bits = "%s %d" % (MONTHS[start.month - 1][0:3], start.day)
    if surface != "":
        date_bits += " - " + surface
    kids.append(line(date_bits, DIM, 0))

    if sq:
        loc = ev.get("location") or {}
        city = (loc.get("city") or (ev.get("venue") or {}).get("displayName") or "").strip()
        if city != "":
            kids.append(line(clip(city.upper(), 15), DIM, 0))
        champ = defending(ev, tours)
        if champ != "":
            kids.append(divider(3))
            kids.append(line("DEFENDING", DIM, 2))
            kids.append(line(clip(champ.upper(), 15), AMBER, 0))
    return render.Column(children = kids)

def defending(ev, tours):
    want = wanted_slugs(tours, False)
    for w in (ev.get("previousWinners") or []):
        if ((w.get("type") or {}).get("slug")) in want:
            return w.get("shortDisplayName") or w.get("displayName") or ""
    return ""

def pages_of(widgets, per_page, header):
    pages = []
    for start in range(0, len(widgets), per_page):
        chunk = widgets[start:start + per_page]
        kids = [header]
        first = True
        for w in chunk:
            kids.append(render.Padding(pad = (1, 0 if first else 1, 1, 0), child = w))
            first = False
        pages.append(render.Column(children = kids))
    return pages

def board_pages(ev, comps, mode, tz, sq, extra):
    per = 4 if sq else 2
    label = {"live": "", "final": "RESULTS", "sched": "TODAY"}[mode]
    rnd = round_label(comps[0]) if len(comps) > 0 else ""
    right = rnd if mode == "live" else label
    colour, _ = surface_for(ev, time.now())
    head = bar(clip((ev.get("shortName") or ev.get("name") or "TENNIS").upper(), 11), right, colour, WHITE)

    widgets = []
    for c in comps:
        w = match_widget(c, mode, tz)
        if w != None:
            widgets.append(w)
    for c in extra:
        w = match_widget(c, "sched", tz)
        if w != None:
            widgets.append(w)
    if len(widgets) == 0:
        return None
    return pages_of(widgets, per, head)

def player_panel(state, comp, ev, who, guid, tz, now, sq):
    kids = [bar(clip(who, 11), round_label(comp), AMBER, BLACK)]

    if state == "advanced":
        kids.append(line("THROUGH TO", WHITE, 2))
        kids.append(line(next_round_name(comp), AMBER, 1))
        kids.append(line("OPPONENT TBD", DIM, 2))
        if sq and ev != None:
            kids.append(divider(3))
            kids.append(line("BEAT", DIM, 2))
            kids.append(line(clip(opponent_of(comp, guid), 15), WHITE, 0))
        return render.Column(children = kids)

    if state == "upcoming":
        kids.append(line(when_text(comp.get("date", ""), tz), WHITE, 2))
        kids.append(line("v " + clip(opponent_of(comp, guid), 12), WHITE, 1))
        start = parse_iso(comp.get("date", ""))
        if start != None:
            big, unit = countdown_text(start, now)
            kids.append(line("IN %s %s" % (big, unit), GREEN, 2))
        if sq and ev != None:
            kids.append(divider(3))
            kids.append(line(clip((ev.get("name") or "").upper(), 15), DIM, 2))
        return render.Column(children = kids)

    return None

def next_round_name(comp):
    r = (comp.get("round") or {}).get("displayName") or ""
    nxt = {
        "Round 1": "ROUND 2",
        "Round 2": "ROUND 3",
        "Round 3": "ROUND 4",
        "Round 4": "QUARTERFINAL",
        "Quarterfinal": "SEMIFINAL",
        "Semifinal": "THE FINAL",
        "Final": "THE TITLE",
    }
    return nxt.get(r, "THE NEXT ROUND")

def opponent_of(comp, guid):
    for c in (comp.get("competitors") or []):
        if guid_of(c) != guid:
            return short_name(c)
    return "TBD"

def notice(msg, sub):
    return render.Column(children = [
        bar("TENNIS", "", HARD, WHITE),
        line(msg, WHITE, 3),
        line(sub, DIM, 1),
    ])

# ---------------------------------------------------------------- player state

def _match_date(m):
    return m[0].get("date", "")

def find_player(events, guid, slugs, quals):
    mine = []
    for ev in events:
        for c in competitions(ev, slugs, quals):
            for x in (c.get("competitors") or []):
                if guid_of(x) == guid:
                    mine.append([c, ev, x])
    return sorted(mine, key = _match_date)

def player_state(events, guid, slugs, quals):
    mine = find_player(events, guid, slugs, quals)
    if len(mine) == 0:
        return "absent", None, None
    for m in mine:
        if state_of(m[0]) == "in":
            return "playing", m[0], m[1]
    for m in mine:
        if state_of(m[0]) == "pre":
            return "upcoming", m[0], m[1]
    last = mine[-1]
    if last[2].get("winner") == True:
        return "advanced", last[0], last[1]
    return "out", last[0], last[1]

# ------------------------------------------------------- slam point by point

def slam_live(year, month):
    """The slam currently on court, or None.

    A finished tournament keeps serving its final board for months, so the test
    has to be "is anyone playing", not "is the list non-empty".
    """
    for feed in SLAM_FEEDS:
        if month not in feed[3]:
            continue
        d = get_json(feed[0] + str(year) + "/matches/live/scores.json", TTL_PBP, SLAM_HEADERS)
        if type(d) != "dict":
            continue
        matches = d.get("matches")
        if type(matches) != "list":
            continue
        playing = []
        for m in matches:
            if type(m) == "dict" and (m.get("status") or "") == "In Progress":
                playing.append(m)
        if len(playing) > 0:
            return [feed[0], feed[1], feed[2], playing]
    return None

def slam_eligible(match, tours, doubles):
    name = match.get("eventName") or ""
    if name in SLAM_SINGLES:
        return SLAM_SINGLES[name] in tours
    if doubles and name in SLAM_DOUBLES:
        want = SLAM_DOUBLES[name]
        return want == "both" or want in tours
    return False

def slam_point(base, year, match_id):
    """The most recent point. The rolling feed is ~5KB and holds the last few."""
    d = get_json(base + str(year) + "/slamtracker/history/" + match_id + "U.json", TTL_PBP, SLAM_HEADERS)
    if type(d) != "list" or len(d) == 0:
        return None
    return d[-1]

def set_result(mine, theirs):
    """Who took a set, from the two game counts. None while it is still live."""
    if not mine.isdigit() or not theirs.isdigit():
        return None
    a = int(mine)
    b = int(theirs)
    if a >= 6 and a - b >= 2:
        return True
    if b >= 6 and b - a >= 2:
        return False
    if a == 7:
        return True
    if b == 7:
        return False
    return None

def slam_sets(match, idx):
    out = []
    for s in ((match.get("scores") or {}).get("sets") or []):
        if len(s) < 2:
            continue
        mine = s[idx].get("scoreDisplay")
        theirs = s[1 - idx].get("scoreDisplay")
        if mine == None:
            continue
        out.append([mine, set_result(mine, theirs or "")])
    return out

def serving_team(point, pairs):
    """Which side is serving, as 1, 2 or 0.

    PointServer numbers the individual player, so in doubles it runs 1-4 with
    the first pair taking 1 and 2 - a bare "is it 2?" test only works for
    singles.
    """
    raw = txt((point or {}).get("PointServer"), "0")
    if not raw.isdigit():
        return 0
    n = int(raw)
    if n < 1:
        return 0
    if pairs:
        return 1 if n <= 2 else 2
    if n <= 2:
        return n
    return 0

def slam_name(team):
    """Singles gets the full surname; a doubles pair has to share the row."""
    a = surname(team.get("displayNameA") or "?")
    b = team.get("displayNameB")
    if b == None or b == "":
        return a
    return a[0:4] + "/" + surname(b)[0:4]

def txt(value, fallback):
    """A feed key can be present carrying JSON null, which returns None from
    .get(key, default) rather than the default - so coerce every read."""
    if type(value) != "string" or value == "":
        return fallback
    return value

def flag(point, name):
    """Flags are player-indexed strings: "0" none, "1"/"2" the player."""
    return txt(point.get(name), "0")

def point_event(point):
    """The most newsworthy thing about the last point.

    Every flag is player-indexed rather than boolean: "0" means it did not
    happen, "1" and "2" name the player it happened to.
    """
    if point == None:
        return "", DIM
    if flag(point, "MatchWinner") != "0":
        return "MATCH", AMBER
    if flag(point, "SetWinner") != "0":
        return "SET", AMBER
    if flag(point, "Ace") != "0":
        mph = txt(point.get("Speed_MPH"), "0")
        if mph != "0":
            return "ACE " + mph, GREEN
        return "ACE", GREEN
    if flag(point, "DoubleFault") != "0":
        return "DBL FAULT", SUSPEND
    if flag(point, "BreakPointWon") != "0":
        return "BREAK", AMBER
    if flag(point, "BreakPoint") != "0":
        return "BREAK PT", AMBER
    if flag(point, "GameWinner") != "0":
        return "GAME", WHITE
    if flag(point, "Winner") != "0":
        return "WINNER", WHITE
    if flag(point, "UnforcedError") != "0":
        return "ERROR", DIM
    return "", DIM

def game_score(point):
    if point == None:
        return ""
    a = txt(point.get("P1Score"), "")
    b = txt(point.get("P2Score"), "")
    if a == "" or b == "":
        return ""
    return a + "-" + b

def slam_page(name, colour, match, point, sq):
    t1 = match.get("team1") or {}
    t2 = match.get("team2") or {}
    pairs = (t1.get("displayNameB") or "") != ""
    server = serving_team(point, pairs)
    kids = [bar(clip(name, 11), match.get("roundNameShort") or "", colour, WHITE)]
    kids.append(render.Padding(pad = (1, 1, 1, 0), child = render.Column(children = [
        player_row(slam_name(t1), slam_sets(match, 0), WHITE, server == 1),
        player_row(slam_name(t2), slam_sets(match, 1), WHITE, server == 2),
    ])))

    event, ink = point_event(point)
    kids.append(render.Padding(pad = (2, 1, 1, 0), child = render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text(game_score(point), font = TT, color = AMBER),
            render.Text(clip(event, 12), font = TT, color = ink),
        ],
    )))

    if sq and point != None:
        kids.append(divider(2))

        # Serve detail first, then the commentary clipped to the room that is
        # left - a long sentence must never push the line below it off-panel.
        serve = txt(point.get("ServeNumber"), "0")
        mph = txt(point.get("Speed_MPH"), "0")
        if serve != "0" and mph != "0":
            ordinal = "1ST" if serve == "1" else "2ND"
            kids.append(line(mph + " MPH ON " + ordinal, AMBER, 2))
        sentence = txt(point.get("Sentence"), "")
        if sentence != "":
            kids.append(render.Padding(pad = (2, 2, 2, 0), child = render.WrappedText(
                content = sentence,
                width = 60,
                height = 21,
                font = TT,
                color = DIM,
                linespacing = 1,
            )))
    return render.Column(children = kids)

def slam_mode(tours, doubles, guid_name, sq, speed, now):
    live = slam_live(now.year, now.month)
    if live == None:
        return None
    base, name, colour, matches = live[0], live[1], live[2], live[3]

    picked = []
    for m in matches:
        if slam_eligible(m, tours, doubles):
            picked.append(m)
    if len(picked) == 0:
        return None

    # Following someone narrows the screen to their match. If they are not on
    # court, hand back to the tour scoreboard rather than showing strangers -
    # only that path knows whether they are up next or already out.
    if guid_name != "":
        mine = []
        for m in picked:
            t1 = slam_name(m.get("team1") or {})
            t2 = slam_name(m.get("team2") or {})
            if t1 == guid_name or t2 == guid_name:
                mine.append(m)
        if len(mine) == 0:
            return None
        picked = mine

    # Every page costs a request and pixlet drops any animation past 15s, so
    # the page count follows the time budget rather than the panel size.
    cap = 15 // int(speed)
    if cap > (4 if sq else 3):
        cap = 4 if sq else 3
    if cap < 1:
        cap = 1
    pages = []
    for m in picked[0:cap]:
        point = slam_point(base, now.year, m.get("match_id") or "")
        pages.append(slam_page(name, colour, m, point, sq))
    if len(pages) == 0:
        return None
    return render.Root(delay = int(speed) * 1000, child = render.Animation(children = pages))

# ---------------------------------------------------------------- main

def main(config):
    now = time.now().in_location("UTC")

    # Test hook, deliberately not in the schema: pin the clock so the
    # between-tournaments path can be exercised while a tournament is running.
    #   pixlet render apps/tennisseason nowiso=2026-09-20T12:00Z
    pinned = parse_iso(config.str("nowiso", ""))
    if pinned != None:
        now = pinned
    now_iso = iso_now(now)
    tz = config.get("$tz", "UTC")
    sq = is_square()

    tour = config.str("tour", "both")
    tours = ["atp"] if tour == "men" else (["wta"] if tour == "women" else ["atp", "wta"])
    slams_only = config.bool("slams", False)
    quals = config.bool("quals", False)
    doubles = config.bool("doubles", False)
    when_out = config.str("whenout", "tournament")
    speed = config.str("speed", "4")
    slugs = wanted_slugs(tours, doubles)

    follow = config.get("player")
    guid = ""
    who = ""
    if follow != None and follow != "":
        parsed = json.decode(follow, None)
        if parsed != None:
            raw = parsed.get("value", "")
            bits = raw.split("|")
            if len(bits) >= 2:
                guid = bits[0]
                who = surname(bits[1])

    # A Grand Slam publishes point-by-point, which beats anything the tour
    # scoreboard carries, so take it whenever there is something on court.
    if config.bool("pbp", True):
        slam = slam_mode(tours, doubles, who, sq, speed, now)
        if slam != None:
            return slam

    running, ahead, days = gather(tours, slams_only, now_iso)

    # --- a followed player takes priority over everything else
    if guid != "" and len(running) > 0:
        state, comp, ev = player_state(running, guid, slugs, quals)
        if state == "playing":
            pages = board_pages(ev, [comp], "live", tz, sq, [])
            if pages != None:
                return render.Root(delay = int(speed) * 1000, child = render.Animation(children = pages))
        elif state == "upcoming" or state == "advanced":
            return render.Root(child = player_panel(state, comp, ev, who, guid, tz, now, sq))
        elif when_out == "quiet":
            return []

    # --- something is on
    for ev in running:
        comps = competitions(ev, slugs, quals)
        live = [c for c in comps if state_of(c) == "in"]
        if len(live) > 0:
            sched = sorted([c for c in comps if state_of(c) == "pre"], key = by_date)
            pages = board_pages(ev, live, "live", tz, sq, sched[0:2] if sq else [])
            if pages != None:
                return render.Root(delay = int(speed) * 1000, child = render.Animation(children = pages))

    for ev in running:
        comps = competitions(ev, slugs, quals)
        done = sorted([c for c in comps if state_of(c) == "post"], key = by_date)
        if len(done) > 0:
            recent = done[-8:]
            recent = sorted(recent, key = by_date, reverse = True)
            pages = board_pages(ev, recent, "final", tz, sq, [])
            if pages != None:
                return render.Root(delay = int(speed) * 1000, child = render.Animation(children = pages))

    for ev in running:
        comps = competitions(ev, slugs, quals)
        sched = sorted([c for c in comps if state_of(c) == "pre"], key = by_date)
        if len(sched) > 0:
            pages = board_pages(ev, sched[0:8], "sched", tz, sq, [])
            if pages != None:
                return render.Root(delay = int(speed) * 1000, child = render.Animation(children = pages))

    # --- nothing on: count down
    sid = ""
    nxt = earliest(ahead)
    if nxt != None:
        sid = (nxt.get("id") or "").split("-")[0]

    if slams_only:
        if nxt == None:
            nxt, sid = next_slam(now, now_iso)

        # ESPN does not publish the next season until late in the year, so the
        # slam gets named by month rather than claiming a date it cannot know.
        if nxt == None:
            return render.Root(child = countdown_panel({}, sid, tours, now, sq))
    elif nxt == None:
        nxt = next_from_calendar(tours, days, slams_only, now_iso)
        if nxt != None:
            sid = (nxt.get("id") or "").split("-")[0]

    if nxt == None:
        return render.Root(child = notice("SEASON BREAK", "NO DATES YET"))
    return render.Root(child = countdown_panel(nxt, sid, tours, now, sq))

# ---------------------------------------------------------------- schema

def search_player(pattern):
    pattern = pattern.strip().lower()
    if len(pattern) < 2:
        return []
    out = []
    for t in ["atp", "wta"]:
        d = get_json(BASE + t + "/rankings", TTL_RANK)
        if d == None:
            continue
        ranks = (d.get("rankings") or [{}])[0].get("ranks") or []
        for r in ranks:
            a = r.get("athlete") or {}
            name = a.get("displayName") or ""
            if pattern in name.lower() and a.get("guid"):
                out.append(schema.Option(
                    display = "%s (%s %d)" % (name, t.upper(), r.get("current", 0)),
                    value = a["guid"] + "|" + (a.get("shortname") or name),
                ))
    return out[0:12]

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "tour",
                name = "Tour",
                desc = "Which tour to follow.",
                icon = "userGroup",
                default = "both",
                options = [
                    schema.Option(display = "Men's and women's", value = "both"),
                    schema.Option(display = "Men's only", value = "men"),
                    schema.Option(display = "Women's only", value = "women"),
                ],
            ),
            schema.Toggle(
                id = "slams",
                name = "Grand slams only",
                desc = "Ignore everything except the four majors.",
                icon = "trophy",
                default = False,
            ),
            schema.Typeahead(
                id = "player",
                name = "Follow a player",
                desc = "Their match takes over the screen. Leave empty to follow the whole tournament.",
                icon = "user",
                handler = search_player,
            ),
            schema.Dropdown(
                id = "whenout",
                name = "When they're out",
                desc = "What to show once your player has been knocked out.",
                icon = "circleQuestion",
                default = "tournament",
                options = [
                    schema.Option(display = "Show the tournament", value = "tournament"),
                    schema.Option(display = "Show nothing", value = "quiet"),
                ],
            ),
            schema.Toggle(
                id = "pbp",
                name = "Point by point",
                desc = "During a Grand Slam, show the live point score and what just happened.",
                icon = "tableTennisPaddleBall",
                default = True,
            ),
            schema.Toggle(
                id = "quals",
                name = "Include qualifying",
                desc = "Qualifying is most of the draw in week one.",
                icon = "filter",
                default = False,
            ),
            schema.Toggle(
                id = "doubles",
                name = "Include doubles",
                desc = "Show doubles matches alongside singles.",
                icon = "users",
                default = False,
            ),
            schema.Dropdown(
                id = "speed",
                name = "Rotation speed",
                desc = "Seconds each page is held.",
                icon = "gaugeHigh",
                default = "4",
                options = [
                    schema.Option(display = "2 seconds", value = "2"),
                    schema.Option(display = "3 seconds", value = "3"),
                    schema.Option(display = "4 seconds", value = "4"),
                    schema.Option(display = "6 seconds", value = "6"),
                ],
            ),
        ],
    )

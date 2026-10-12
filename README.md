# TOCA Madison — Full League Schedule

A full schedule for the TOCA Madison adult soccer league (**all teams, all
divisions**), not just the teams you're on. The official site
(`bondsports.co/user/schedule`) only shows your own games; this rebuilds the
complete league schedule from Bond Sports' public API.

## View it

**https://cooperthompson.github.io/toca-schedules/toca-schedule.html**

A single self-contained page: filter by team/division/date, click any column to
sort, grouped by day. By default it shows the **current and upcoming** seasons
(finished seasons are hidden).

## Add games to your calendar

Each division/season is published as an `.ics` file under [`ics/`](ics/). From
the page you can, per season:

- **Download .ics** — import once into any calendar app.
- **Subscribe (Google)** — opens Google Calendar's "add calendar" prompt.
- **Subscribe (Apple/Outlook)** — a `webcal://` link those apps handle directly.

**Subscriptions auto-update**, so when games are rescheduled the calendar
follows — but note **Google only re-polls external calendars every ~8–24 hours**
(sometimes longer), so changes are not instant. A one-time **Download** is
immediate but won't update.

To subscribe manually in Google Calendar: *Other calendars → From URL →* paste
the season's ICS URL, e.g.
`https://cooperthompson.github.io/toca-schedules/ics/Mon-Weds-Coed-Recreational-Winter-1.ics`

## Regenerate / update

Requires PowerShell. Re-run whenever the league posts new games or a new season:

```powershell
# Default: current/upcoming seasons, subscribe links pointing at GitHub Pages
./Get-TocaSchedule.ps1

# Include finished seasons too
./Get-TocaSchedule.ps1 -IncludePast

# Point the subscribe links at a different host
./Get-TocaSchedule.ps1 -BaseUrl "https://<bucket>.s3.amazonaws.com"
```

Then commit and push `toca-schedule.html` and `ics/`:

```powershell
git add -A; git commit -m "Refresh schedule"; git push
```

| Parameter | Default | Purpose |
|---|---|---|
| `-ProgramId` | `11545` | Bond Sports program (the TOCA Madison adult league) |
| `-BaseUrl` | GitHub Pages URL | Public base where `ics/` is hosted; set `""` to omit subscribe links |
| `-IncludePast` | off | Also show seasons that have already ended |
| `-SeasonFilter` | — | Only seasons whose name matches a substring (e.g. `Winter`) |
| `-OutFile` | `toca-schedule.html` | Output HTML path |

## How it works (public Bond Sports API, no login)

```
GET /v4/programs-seasons/program/{programId}   -> all seasons/divisions in the league
GET /v4/programs-seasons/{seasonId}/events      -> every game in a season (100/page)
GET /v4/resources/{spaceId}                     -> field name (Field 1 / Field 2)
```

Event `startDate`/`endDate` are UTC (the real game times), which the `.ics`
files use directly. The generator pages through all events, resolves field
names, writes the HTML, and writes one `.ics` per season.

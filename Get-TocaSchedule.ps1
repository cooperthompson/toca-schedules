<#
.SYNOPSIS
  Builds a full league schedule for a Bond Sports program by calling the PUBLIC
  (no-auth) season events API, server-side, so it is NOT filtered to your teams.
  Produces a self-contained HTML viewer plus one .ics calendar file per season.

.DESCRIPTION
  The bondsports.co site shows /user/{id}/activity, which is scoped to the teams
  you are on. The underlying data for a whole league lives under each season:

      GET /v4/programs-seasons/program/{programId}   -> all seasons in the league
      GET /v4/programs-seasons/{seasonId}/events      -> every game in that season
      GET /v4/resources/{spaceId}                     -> field/space name

  None of these need a login. This script enumerates the seasons, pages through
  all events, resolves field names, writes a filterable/sortable HTML file, and
  writes an .ics file per season (into .\ics). The HTML links each season's .ics
  and gives every game an "Add to Google Calendar" link.

.EXAMPLE
  ./Get-TocaSchedule.ps1
  ./Get-TocaSchedule.ps1 -ProgramId 11545 -OutFile my-schedule.html
  ./Get-TocaSchedule.ps1 -SeasonFilter 'Winter'   # only seasons whose name matches
#>
[CmdletBinding()]
param(
    [int]    $ProgramId    = 11545,                 # TOCA Madison adult league
    [string] $OutFile      = "index.html",          # site root so .../toca-schedules/ serves it
    [string] $IcsDir       = "ics",
    [string] $SeasonFilter = "",                    # substring match on season name (optional)
    [string] $FacilityName = "TOCA - Madison, WI",
    [string] $BaseUrl      = "https://cooperthompson.github.io/toca-schedules",  # public HTTPS
                                                     # base where ics/ is hosted. Enables the
                                                     # season-level Subscribe links. Set "" to disable.
    [switch] $IncludePast,                           # also show seasons that have already ended
    [string] $ApiBase      = "https://api.bondsports.co/v4"
)
$BaseUrl = $BaseUrl.TrimEnd('/')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

function Get-Json($url) {
    Invoke-RestMethod -Uri $url -Method Get -Headers @{ 'Accept' = 'application/json' }
}

# ICS text escaping per RFC 5545 (escape backslash, comma, semicolon, newlines)
function Convert-IcsText($s) {
    if ($null -eq $s) { return "" }
    ($s -replace '\\', '\\' -replace ',', '\,' -replace ';', '\;' -replace "`r`n|`n|`r", '\n')
}

# ISO-8601 (…Z) -> ICS/Google UTC stamp 20261013T013000Z
function Convert-IcsStamp($iso) {
    if (-not $iso) { return $null }
    ([datetime]::Parse($iso, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    ).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
}

function Get-Slug($s) {
    (($s -replace '[^A-Za-z0-9]+', '-') -replace '(^-+|-+$)', '')
}

# spaceId -> field name, cached
$fieldCache = @{}
function Resolve-Field($id) {
    if (-not $id) { return "" }
    if ($fieldCache.ContainsKey($id)) { return $fieldCache[$id] }
    $name = ""
    try {
        $r = Get-Json "$ApiBase/resources/$id"
        if ($r.data.name) { $name = $r.data.name }
    } catch { }
    $fieldCache[$id] = $name
    return $name
}

Write-Host "Fetching seasons for program $ProgramId ..." -ForegroundColor Cyan
$seasons = (Get-Json "$ApiBase/programs-seasons/program/$ProgramId").data
if (-not $seasons) { throw "No seasons returned for program $ProgramId." }

if ($SeasonFilter) {
    $seasons = $seasons | Where-Object { $_.name -like "*$SeasonFilter*" }
    Write-Host "  filtered to $($seasons.Count) season(s) matching '$SeasonFilter'" -ForegroundColor DarkCyan
}

if (-not $IncludePast) {
    $today = (Get-Date).Date
    $seasons = $seasons | Where-Object {
        -not $_.endDate -or [datetime]::Parse($_.endDate, [cultureinfo]::InvariantCulture).Date -ge $today
    }
    Write-Host "  showing $($seasons.Count) current/upcoming season(s) (use -IncludePast for finished ones)" -ForegroundColor DarkCyan
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($s in $seasons) {
    $page = 1
    do {
        $url  = "$ApiBase/programs-seasons/$($s.id)/events?page=$page&itemsPerPage=100"
        $resp = Get-Json $url
        foreach ($e in $resp.events) {
            $spaceId = if ($e.slots -and $e.slots[0]) { $e.slots[0].spaceId } else { $null }
            $rows.Add([pscustomobject]@{
                eventId  = $e.id
                date     = $e.startDateString          # yyyy/MM/dd (local)
                start    = $e.startTime                 # HH:mm:ss (local)
                end      = $e.endTime
                startUtc = $e.startDate                 # ISO UTC
                endUtc   = $e.endDate
                season   = $s.name
                seasonId = $s.id
                title    = $e.title
                field    = (Resolve-Field $spaceId)
                notes    = if ($e.slots -and $e.slots[0]) { $e.slots[0].publicNotes } else { $e.publicNotes }
            })
        }
        $totalPages = if ($resp.meta.totalPages) { [int]$resp.meta.totalPages } else { 1 }
        $page++
    } while ($page -le $totalPages)
    Write-Host ("  {0,-45} {1,4} games" -f $s.name, ($rows | Where-Object season -eq $s.name).Count)
}

$rows = $rows | Sort-Object @{e={$_.date}}, @{e={$_.start}}
Write-Host "Total games: $($rows.Count)" -ForegroundColor Green

# ---------------------------------------------------------------- ICS per season
if (-not (Test-Path $IcsDir)) { New-Item -ItemType Directory -Path $IcsDir | Out-Null }
Get-ChildItem -LiteralPath $IcsDir -Filter *.ics -ErrorAction SilentlyContinue | Remove-Item -Force  # drop stale seasons
$dtstamp  = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$icsFiles = @()

foreach ($s in $seasons) {
    $items = $rows | Where-Object seasonId -eq $s.id
    if (-not $items) { continue }
    $slug = Get-Slug $s.name

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("BEGIN:VCALENDAR")
    [void]$sb.AppendLine("VERSION:2.0")
    [void]$sb.AppendLine("PRODID:-//toca-schedule//EN")
    [void]$sb.AppendLine("CALSCALE:GREGORIAN")
    [void]$sb.AppendLine("METHOD:PUBLISH")
    [void]$sb.AppendLine("X-WR-CALNAME:" + (Convert-IcsText $s.name))
    foreach ($g in $items) {
        $dts = Convert-IcsStamp $g.startUtc
        $dte = Convert-IcsStamp $g.endUtc
        if (-not $dts) { continue }
        $loc = if ($g.field) { "$FacilityName - $($g.field)" } else { $FacilityName }
        [void]$sb.AppendLine("BEGIN:VEVENT")
        [void]$sb.AppendLine("UID:bond-$($g.eventId)@bondsports")
        [void]$sb.AppendLine("DTSTAMP:$dtstamp")
        [void]$sb.AppendLine("DTSTART:$dts")
        if ($dte) { [void]$sb.AppendLine("DTEND:$dte") }
        [void]$sb.AppendLine("SUMMARY:" + (Convert-IcsText $g.title))
        [void]$sb.AppendLine("LOCATION:" + (Convert-IcsText $loc))
        [void]$sb.AppendLine("DESCRIPTION:" + (Convert-IcsText ("$($s.name)" + $(if ($g.notes) { " - $($g.notes)" } else { "" }))))
        [void]$sb.AppendLine("END:VEVENT")
    }
    [void]$sb.AppendLine("END:VCALENDAR")

    $text = ($sb.ToString() -replace "`r`n", "`n") -replace "`n", "`r`n"   # ICS wants CRLF
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $IcsDir).Path + "\$slug.ics", $text, (New-Object System.Text.UTF8Encoding($false)))
    $icsFiles += [pscustomobject]@{ name = $s.name; file = "$IcsDir/$slug.ics"; games = $items.Count }
    Write-Host ("  ics: {0,-45} {1,4} events" -f $s.name, $items.Count) -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------- HTML viewer
$generated = Get-Date -Format "yyyy-MM-dd HH:mm"
$json = ($rows | Select-Object date,start,end,startUtc,endUtc,season,title,field,notes | ConvertTo-Json -Depth 4 -Compress)
$json = $json -replace '</', '<\/'

$icsLinks = ($icsFiles | ForEach-Object {
    $nameHtml = [System.Web.HttpUtility]::HtmlEncode($_.name)
    $dl = '<a href="' + $_.file + '" download>Download .ics</a>'
    $subscribe = ''
    if ($BaseUrl) {
        $httpsUrl = "$BaseUrl/$($_.file)"
        $webcal   = $httpsUrl -replace '^https?://', 'webcal://'
        $gcal     = 'https://calendar.google.com/calendar/r?cid=' + [uri]::EscapeDataString($webcal)
        $subscribe = ' &middot; Subscribe: <a href="' + [System.Web.HttpUtility]::HtmlEncode($gcal) + '" target="_blank" rel="noopener">Google</a>' +
                     ' &middot; <a href="' + [System.Web.HttpUtility]::HtmlEncode($webcal) + '">Apple/Outlook</a>'
    }
    '<li><strong>' + $nameHtml + '</strong> <span class="g">(' + $_.games + ' games)</span><br>' + $dl + $subscribe + '</li>'
}) -join "`n"
if (-not $icsLinks) { $icsLinks = '<li><em>no seasons with games</em></li>' }

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TOCA Madison - Full League Schedule</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; padding: 1.25rem; }
  h1 { font-size: 1.25rem; margin: 0 0 .25rem; }
  h2 { font-size: .95rem; margin: 1.25rem 0 .4rem; }
  .meta { color: #6b7280; font-size: .85rem; margin-bottom: 1rem; }
  .controls { display: flex; flex-wrap: wrap; gap: .5rem; margin-bottom: 1rem; }
  input, select { padding: .45rem .6rem; border: 1px solid #cbd5e1; border-radius: .5rem; font-size: .9rem; }
  input#q { flex: 1 1 260px; }
  table { border-collapse: collapse; width: 100%; font-size: .9rem; }
  th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid #e5e7eb; white-space: nowrap; }
  th { position: sticky; top: 0; background: Canvas; cursor: pointer; user-select: none; }
  th:hover { color: #2563eb; }
  td.title { white-space: normal; font-weight: 600; }
  tr:hover td { background: rgba(37,99,235,.06); }
  .count { color: #6b7280; font-size: .85rem; margin: .5rem 0; }
  .daybreak td { background: rgba(37,99,235,.10); font-weight: 700; }
  ul.ics { columns: 2; max-width: 760px; padding-left: 1.1rem; font-size: .9rem; }
  ul.ics li { margin: .15rem 0; }
  ul.ics .g { color: #6b7280; }
  a.gcal { text-decoration: none; font-size: .85rem; white-space: nowrap; }
  a { color: #2563eb; }
</style>
</head>
<body>
  <h1>TOCA Madison &mdash; Full League Schedule</h1>
  <div class="meta">Program $ProgramId &middot; all divisions / seasons &middot; generated $generated &middot; source: public programs-seasons events API</div>

  <h2>Add a whole division / season to your calendar</h2>
  <ul class="ics">
$icsLinks
  </ul>

  <h2>Browse all games</h2>
  <div class="controls">
    <input id="q" type="search" placeholder="Filter by team, division, date&hellip;">
    <select id="season"><option value="">All seasons / divisions</option></select>
  </div>
  <div class="count" id="count"></div>
  <table id="t">
    <thead><tr>
      <th data-k="date">Date</th>
      <th data-k="start">Time</th>
      <th data-k="title">Matchup</th>
      <th data-k="season">Division / Season</th>
      <th data-k="field">Field</th>
    </tr></thead>
    <tbody></tbody>
  </table>

<script id="data" type="application/json">$json</script>
<script>
  const rows = JSON.parse(document.getElementById('data').textContent);
  const tbody = document.querySelector('#t tbody');
  const q = document.getElementById('q');
  const seasonSel = document.getElementById('season');
  const count = document.getElementById('count');
  let sortK = 'date', sortAsc = true;

  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  function fmtDate(d) {              // "2026/10/12" -> "Oct 12, 2026"
    if (!d) return '';
    const [y, m, day] = d.split('/').map(Number);
    return MONTHS[m - 1] + ' ' + day + ', ' + y;
  }
  function fmtTime(t) {              // "18:30:00" -> "6:30 pm"
    if (!t) return '';
    let [h, mi] = t.split(':').map(Number);
    const ap = h >= 12 ? 'pm' : 'am';
    h = h % 12; if (h === 0) h = 12;
    return h + ':' + String(mi).padStart(2, '0') + ' ' + ap;
  }
  [...new Set(rows.map(r => r.season))].sort().forEach(s => {
    const o = document.createElement('option'); o.value = s; o.textContent = s; seasonSel.appendChild(o);
  });

  function render() {
    const term = q.value.trim().toLowerCase();
    const seas = seasonSel.value;
    let data = rows.filter(r => {
      if (seas && r.season !== seas) return false;
      if (!term) return true;
      return [fmtDate(r.date), r.date, r.title, r.season, r.field, r.notes]
        .some(v => (v ?? '').toString().toLowerCase().includes(term));
    });
    data.sort((a, b) => {
      const x = (a[sortK] ?? ''), y = (b[sortK] ?? '');
      return (x > y ? 1 : x < y ? -1 : 0) * (sortAsc ? 1 : -1);
    });
    tbody.innerHTML = '';
    let lastDay = null;
    for (const r of data) {
      if (r.date !== lastDay && sortK === 'date') {
        lastDay = r.date;
        const br = tbody.insertRow(); br.className = 'daybreak';
        const c = br.insertCell(); c.colSpan = 5; c.textContent = fmtDate(r.date);
      }
      const tr = tbody.insertRow();
      tr.insertCell().textContent = fmtDate(r.date);
      tr.insertCell().textContent = fmtTime(r.start) + (r.end ? ' - ' + fmtTime(r.end) : '');
      const td = tr.insertCell(); td.textContent = r.title; td.className = 'title';
      tr.insertCell().textContent = r.season;
      tr.insertCell().textContent = r.field || '';
    }
    count.textContent = data.length + ' of ' + rows.length + ' games';
  }

  document.querySelectorAll('th[data-k]').forEach(th => th.addEventListener('click', () => {
    const k = th.dataset.k;
    if (k === sortK) sortAsc = !sortAsc; else { sortK = k; sortAsc = true; }
    render();
  }));
  q.addEventListener('input', render);
  seasonSel.addEventListener('change', render);
  render();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutFile), $html, (New-Object System.Text.UTF8Encoding($false)))

# keep the old /toca-schedule.html link working by redirecting it to the canonical page
$outName = [System.IO.Path]::GetFileName($OutFile)
if ($outName -ne 'toca-schedule.html') {
    $redirect = @"
<!doctype html>
<meta charset="utf-8">
<title>TOCA Madison Schedule</title>
<meta http-equiv="refresh" content="0; url=./$outName">
<link rel="canonical" href="./$outName">
<p>Redirecting to <a href="./$outName">the schedule</a>&hellip;</p>
"@
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath('toca-schedule.html'), $redirect, (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host "Wrote $OutFile (+ toca-schedule.html redirect) and $($icsFiles.Count) .ics file(s) in .\$IcsDir" -ForegroundColor Green

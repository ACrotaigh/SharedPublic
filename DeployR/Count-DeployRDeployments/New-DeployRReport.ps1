<#
.SYNOPSIS
    Builds a full-history daily-counts CSV and a windowed HTML report from
    collected DeployR audit history.

.DESCRIPTION
    Reads the raw event history produced by Export-DeployRAuditHistory.ps1 and
    produces two outputs with independent scope:

      * The daily CSV always covers the ENTIRE collected history. It is the
        durable record and is never truncated by the report window.
      * The HTML report covers the last -ReportDays days only (30 by default),
        so it stays readable as history accumulates.

    No DeployR authentication and no event log access -- this works purely from
    the collected CSV, so it can run anywhere, including off the server.

    The daily CSV is REGENERATED on every run rather than appended to. Today's
    counts keep changing as the day progresses, so appending would either
    duplicate the row or freeze it at whatever the figure was when the task
    fired. Regenerating from the raw history is always correct and self-heals
    if a run is missed.

    Days with no activity are emitted as explicit zero rows, so gaps mean
    "nothing happened" rather than "no data collected".

    The HTML is entirely self-contained: inline SVG and inline CSS, no
    JavaScript, no external fonts or libraries. It renders on a server with no
    internet access and survives being emailed as an attachment.

.PARAMETER HistoryPath
    Raw event CSV from Export-DeployRAuditHistory.ps1.

.PARAMETER DailyCsvPath
    Output path for the daily rollup CSV. Always full history, regenerated
    each run.

.PARAMETER HtmlPath
    Output path for the HTML report.

.PARAMETER ReportDays
    Days shown in the HTML report, counting back from today. Defaults to 30.
    Use 0 to report on the full history. Does not affect the CSV.

.PARAMETER Layout
    Charts  Daily bar charts, with the figures in a collapsed table. Default.
    Table   Figures only, no charts. Stays readable at any range, so this is
            the sensible choice for long windows.
    Both    Charts with the table expanded beneath.

.EXAMPLE
    .\New-DeployRReport.ps1 -HistoryPath C:\Reports\deployr-history.csv `
                            -DailyCsvPath C:\Reports\deployr-daily.csv `
                            -HtmlPath C:\Reports\deployr.html

.EXAMPLE
    # Quarterly figures as a table
    .\New-DeployRReport.ps1 -HistoryPath C:\Reports\deployr-history.csv `
                            -DailyCsvPath C:\Reports\deployr-daily.csv `
                            -HtmlPath C:\Reports\deployr-q.html `
                            -ReportDays 90 -Layout Table

.NOTES
    Event IDs, confirmed against a live DeployR 1.x Community server:

        17002  Task sequence starting
        17003  Task sequence ended successfully
        17004  Task sequence ended in failure
        23001  Successfully authenticated using passcode
        23006  Failed passcode authentication

    Starts will not reconcile exactly with successes plus failures. A sequence
    that is abandoned -- machine powered off, reverted, or pulled mid-image --
    logs a start and no outcome. A sequence running over midnight logs its start
    and its outcome on different days. Both are expected; neither is an error.

    CHART DENSITY: daily bars stop being legible somewhere past a year, because
    bar width collapses to its minimum and the gaps close up. Use -Layout Table
    for long windows rather than squinting at hairlines.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HistoryPath,

    [string]$DailyCsvPath = 'deployr-daily.csv',

    [string]$HtmlPath = 'deployr-report.html',

    [Alias('Days')]
    [ValidateRange(0, 3650)]
    [int]$ReportDays = 30,

    [ValidateSet('Charts', 'Table', 'Both')]
    [string]$Layout = 'Charts'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $HistoryPath)) {
    throw "History file not found: $HistoryPath. Run Export-DeployRAuditHistory.ps1 first."
}

# EventId -> column name, label and colour. Order drives the report layout.
$metrics = @(
    @{ Id = '17002'; Key = 'Started';    Label = 'Task sequences started'; Note = 'Rebuild volume';                 Colour = '#4a6076' }
    @{ Id = '17003'; Key = 'Succeeded';  Label = 'Ended successfully';     Note = 'Completed rebuilds';             Colour = '#2f7d5b' }
    @{ Id = '17004'; Key = 'Failed';     Label = 'Ended in failure';       Note = 'Step or content failures';       Colour = '#b8412f' }
    @{ Id = '23001'; Key = 'AuthOk';     Label = 'Passcode accepted';      Note = 'Reached the sequence menu';      Colour = '#3a6ea5' }
    @{ Id = '23006'; Key = 'AuthFailed'; Label = 'Passcode rejected';      Note = 'Mistyped, or unexpected client'; Colour = '#b07d2b' }
)

# --- Load and roll up FULL history ----------------------------------------
$raw = @(Import-Csv $HistoryPath)
if (-not $raw.Count) { throw "History file is empty: $HistoryPath" }

$parsed = foreach ($r in $raw) {
    [pscustomobject]@{
        Date    = ([datetime]::Parse($r.TimeCreated, [cultureinfo]::InvariantCulture)).Date
        EventId = [string]$r.EventId
    }
}

$today  = (Get-Date).Date
$first  = ($parsed | Measure-Object Date -Minimum).Minimum
$last   = [datetime]([math]::Max($today.Ticks, ($parsed | Measure-Object Date -Maximum).Maximum.Ticks))
$byDate = $parsed | Group-Object { $_.Date.ToString('yyyy-MM-dd') } -AsHashTable -AsString

$daily = for ($d = $first; $d -le $last; $d = $d.AddDays(1)) {
    $key    = $d.ToString('yyyy-MM-dd')
    $events = if ($byDate -and $byDate.ContainsKey($key)) { @($byDate[$key]) } else { @() }
    $row    = [ordered]@{ Date = $key }
    foreach ($m in $metrics) {
        $row[$m.Key] = @($events | Where-Object EventId -eq $m.Id).Count
    }
    $row['Weekend'] = $d.DayOfWeek -in @('Saturday', 'Sunday')
    [pscustomobject]$row
}
$daily = @($daily)

# CSV: always the whole thing.
$csvDir = Split-Path $DailyCsvPath -Parent
if ($csvDir -and -not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
$daily | Select-Object * -ExcludeProperty Weekend |
    Export-Csv -Path $DailyCsvPath -NoTypeInformation -Encoding UTF8

# Report: the window only.
if ($ReportDays -gt 0) {
    $windowStart = $today.AddDays(-($ReportDays - 1)).ToString('yyyy-MM-dd')
    $report = @($daily | Where-Object { $_.Date -ge $windowStart })
}
else {
    $report = $daily
}
if (-not $report.Count) {
    Write-Warning "No days fall inside the last $ReportDays day(s); reporting on full history instead."
    $report = $daily
}

# --- SVG chart ------------------------------------------------------------
function New-BarTrace {
    param(
        [int[]]$Values,
        [bool[]]$Weekend,
        [string]$Colour,
        [string]$AriaLabel,
        [int]$Width  = 960,
        [int]$Height = 84
    )

    $n = $Values.Count
    if ($n -eq 0) { return '' }

    $max = ($Values | Measure-Object -Maximum).Maximum
    if (-not $max -or $max -le 0) { $max = 1 }

    $base = $Height - 1
    $plot = $Height - 14
    $slot = $Width / $n
    $bw   = [math]::Max(1.5, [math]::Min(22, $slot * 0.66))

    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("<svg class=""trace"" viewBox=""0 0 $Width $Height"" preserveAspectRatio=""none"" role=""img"" aria-label=""$AriaLabel"">")

    for ($i = 0; $i -lt $n; $i++) {
        if ($Weekend[$i]) {
            $x = [math]::Round($i * $slot, 2)
            [void]$sb.Append("<rect class=""wknd"" x=""$x"" y=""0"" width=""$([math]::Round($slot,2))"" height=""$Height""/>")
        }
    }

    [void]$sb.Append("<line class=""axis"" x1=""0"" y1=""$base"" x2=""$Width"" y2=""$base""/>")

    for ($i = 0; $i -lt $n; $i++) {
        $v = $Values[$i]
        if ($v -le 0) { continue }
        $h = [math]::Max(1.5, ($v / $max) * $plot)
        $x = [math]::Round(($i * $slot) + (($slot - $bw) / 2), 2)
        $y = [math]::Round($base - $h, 2)
        [void]$sb.Append("<rect x=""$x"" y=""$y"" width=""$([math]::Round($bw,2))"" height=""$([math]::Round($h,2))"" fill=""$Colour""/>")
    }

    [void]$sb.Append('</svg>')
    $sb.ToString()
}

function ConvertTo-HtmlText { param([string]$Text) [System.Net.WebUtility]::HtmlEncode($Text) }

# --- Build HTML -----------------------------------------------------------
$dates    = @($report.Date)
$weekend  = [bool[]]@($report.Weekend)
$rangeTxt = "$($dates[0]) to $($dates[-1])"
$genTxt   = (Get-Date).ToString('dd MMM yyyy HH:mm')
$histTxt  = "CSV holds $($daily.Count) days from $($daily[0].Date)"

$css = @'
:root{
  --ink:#131a22; --muted:#5d6b7a; --faint:#8b97a4;
  --paper:#f6f7f9; --card:#ffffff; --line:#d9dee5; --band:#eef1f5;
  --sans:"Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,sans-serif;
  --mono:"Cascadia Mono",Consolas,ui-monospace,"SF Mono",monospace;
}
*{box-sizing:border-box}
body{margin:0;padding:32px 24px 64px;background:var(--paper);color:var(--ink);
     font-family:var(--sans);font-size:14px;line-height:1.5;
     -webkit-font-smoothing:antialiased}
.wrap{max-width:1080px;margin:0 auto}
header{border-bottom:2px solid var(--ink);padding-bottom:14px;margin-bottom:28px}
h1{margin:0;font-size:20px;font-weight:600;letter-spacing:-.01em}
.sub{margin-top:4px;color:var(--muted);font-family:var(--mono);font-size:12px}
.sub em{font-style:normal;color:var(--faint)}
.totals{display:flex;flex-wrap:wrap;gap:1px;background:var(--line);
        border:1px solid var(--line);margin-bottom:34px}
.tot{flex:1 1 150px;background:var(--card);padding:14px 16px}
.tot .n{font-family:var(--mono);font-size:26px;font-weight:600;line-height:1.1;
        display:block;font-variant-numeric:tabular-nums}
.tot .k{display:block;margin-top:3px;font-size:11px;color:var(--muted);
        text-transform:uppercase;letter-spacing:.07em}
.trace-row{border-top:1px solid var(--line);padding:16px 0 10px}
.trace-row:last-of-type{border-bottom:1px solid var(--line)}
.thead{display:flex;align-items:baseline;justify-content:space-between;
       gap:16px;margin-bottom:8px}
.tname{font-size:13px;font-weight:600}
.tnote{font-size:11px;color:var(--faint);font-weight:400;margin-left:8px}
.tfig{font-family:var(--mono);font-size:13px;color:var(--muted);
      font-variant-numeric:tabular-nums;white-space:nowrap}
.tfig b{color:var(--ink);font-weight:600}
.trace{display:block;width:100%;height:84px}
.trace .axis{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
.trace .wknd{fill:var(--band)}
.xaxis{display:flex;margin-top:6px;font-family:var(--mono);font-size:10px;
       color:var(--faint)}
.xaxis span{flex:1 1 0;text-align:center;overflow:hidden;white-space:nowrap}
table{border-collapse:collapse;width:100%;font-family:var(--mono);
      font-size:11.5px;font-variant-numeric:tabular-nums;background:var(--card)}
caption{text-align:left;font-family:var(--sans);font-size:13px;font-weight:600;
        padding-bottom:8px}
th,td{text-align:right;padding:4px 10px;border-bottom:1px solid var(--line)}
th:first-child,td:first-child{text-align:left}
thead th{font-weight:600;color:var(--muted);font-size:10.5px;
         text-transform:uppercase;letter-spacing:.06em;
         border-bottom:1px solid var(--ink);position:sticky;top:0;
         background:var(--card)}
tbody tr.wknd td{background:var(--band)}
tbody tr td.zero{color:var(--faint)}
tfoot td{font-weight:600;border-top:1px solid var(--ink);border-bottom:none;
         background:var(--card)}
.tablewrap{border:1px solid var(--line)}
details{margin-top:26px}
summary{cursor:pointer;font-size:12px;color:var(--muted);padding:4px 0}
summary:focus-visible{outline:2px solid var(--ink);outline-offset:2px}
footer{margin-top:32px;padding-top:14px;border-top:1px solid var(--line);
       color:var(--faint);font-size:11.5px;max-width:70ch}
footer p{margin:0 0 6px}
@media (max-width:640px){
  body{padding:20px 14px 40px}
  .tot .n{font-size:20px}
  .trace{height:64px}
  .xaxis{display:none}
  th,td{padding:4px 6px}
}
@media print{
  body{background:#fff;padding:0}
  .trace-row{break-inside:avoid}
  thead th{position:static}
}
'@

$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
[void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$sb.AppendLine('<title>DeployR activity</title>')
[void]$sb.AppendLine("<style>$css</style></head><body><div class=""wrap"">")

[void]$sb.AppendLine('<header><h1>DeployR activity</h1>')
[void]$sb.AppendLine("<div class=""sub"">$rangeTxt &nbsp;&middot;&nbsp; $($report.Count) days &nbsp;&middot;&nbsp; generated $genTxt<br><em>$histTxt</em></div></header>")

# Totals strip -- always shown, scoped to the report window.
[void]$sb.AppendLine('<div class="totals">')
foreach ($m in $metrics) {
    $total = ($report.($m.Key) | Measure-Object -Sum).Sum
    if (-not $total) { $total = 0 }
    [void]$sb.AppendLine("<div class=""tot""><span class=""n"" style=""color:$($m.Colour)"">$total</span><span class=""k"">$(ConvertTo-HtmlText $m.Key)</span></div>")
}
[void]$sb.AppendLine('</div>')

# Charts
if ($Layout -in 'Charts', 'Both') {
    foreach ($m in $metrics) {
        $vals  = [int[]]@($report.($m.Key))
        $total = ($vals | Measure-Object -Sum).Sum
        $peak  = ($vals | Measure-Object -Maximum).Maximum
        $label = ConvertTo-HtmlText $m.Label
        $note  = ConvertTo-HtmlText $m.Note

        [void]$sb.AppendLine('<div class="trace-row"><div class="thead">')
        [void]$sb.AppendLine("<div class=""tname"">$label<span class=""tnote"">$note</span></div>")
        [void]$sb.AppendLine("<div class=""tfig""><b>$total</b> total &nbsp; peak <b>$peak</b>/day</div></div>")
        [void]$sb.AppendLine((New-BarTrace -Values $vals -Weekend $weekend -Colour $m.Colour -AriaLabel "$label, daily counts"))
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('<div class="xaxis">')
    $step = [math]::Max(1, [math]::Ceiling($dates.Count / 12))
    for ($i = 0; $i -lt $dates.Count; $i++) {
        $txt = if ($i % $step -eq 0) { ([datetime]$dates[$i]).ToString('dd MMM') } else { '' }
        [void]$sb.Append("<span>$txt</span>")
    }
    [void]$sb.AppendLine('</div>')
}

# Table
$tableHtml = [Text.StringBuilder]::new()
[void]$tableHtml.AppendLine('<div class="tablewrap"><table><thead><tr><th>Date</th>')
foreach ($m in $metrics) { [void]$tableHtml.Append("<th>$(ConvertTo-HtmlText $m.Key)</th>") }
[void]$tableHtml.AppendLine('</tr></thead><tbody>')
foreach ($row in ($report | Sort-Object Date -Descending)) {
    $cls = if ($row.Weekend) { ' class="wknd"' } else { '' }
    [void]$tableHtml.Append("<tr$cls><td>$($row.Date)</td>")
    foreach ($m in $metrics) {
        $v  = $row.($m.Key)
        $zc = if ($v -eq 0) { ' class="zero"' } else { '' }
        [void]$tableHtml.Append("<td$zc>$v</td>")
    }
    [void]$tableHtml.AppendLine('</tr>')
}
[void]$tableHtml.AppendLine('</tbody><tfoot><tr><td>Total</td>')
foreach ($m in $metrics) {
    $t = ($report.($m.Key) | Measure-Object -Sum).Sum
    if (-not $t) { $t = 0 }
    [void]$tableHtml.Append("<td>$t</td>")
}
[void]$tableHtml.AppendLine('</tr></tfoot></table></div>')

switch ($Layout) {
    'Charts' {
        [void]$sb.AppendLine('<details><summary>Show daily figures</summary>')
        [void]$sb.AppendLine($tableHtml.ToString())
        [void]$sb.AppendLine('</details>')
    }
    default {
        [void]$sb.AppendLine('<div style="margin-top:26px">')
        [void]$sb.AppendLine($tableHtml.ToString())
        [void]$sb.AppendLine('</div>')
    }
}

[void]$sb.AppendLine('<footer>')
[void]$sb.AppendLine('<p>Starts will not reconcile exactly with successes plus failures. A sequence that is abandoned &mdash; machine powered off, reverted, or pulled mid-image &mdash; logs a start and no outcome, and a sequence running over midnight logs its start and its outcome on different days.</p>')
[void]$sb.AppendLine('<p>Passcode acceptances normally exceed starts: an operator can reach the sequence menu and back out without deploying. A widening gap is worth a look.</p>')
[void]$sb.AppendLine('<p>Shaded rows and columns are weekends. Source: TwoPintSoftware-DeployR-Audit/Operational.</p>')
[void]$sb.AppendLine('</footer></div></body></html>')

$htmlDir = Split-Path $HtmlPath -Parent
if ($htmlDir -and -not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
Set-Content -Path $HtmlPath -Value $sb.ToString() -Encoding UTF8

[pscustomobject]@{
    CsvDays     = $daily.Count
    ReportDays  = $report.Count
    Layout      = $Layout
    DailyCsv    = (Resolve-Path $DailyCsvPath).Path
    Html        = (Resolve-Path $HtmlPath).Path
}

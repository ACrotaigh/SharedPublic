# DeployR Deployment Reporting

Counts OS deployment activity (starts, successes, failures, passcode
authentications) from the DeployR server's audit event log, and turns it into
a daily CSV and an HTML report.

Built for **DeployR Community Edition**, break/fix re-imaging scenarios where
devices have no identity until Autopilot enrolment. No DeployR login or API
access is required — everything here reads the Windows event log only.

## How it works

Two scripts, run in sequence:

1. **`Export-DeployRAuditHistory.ps1`** — the collector.
   Reads the `TwoPintSoftware-DeployR-Audit/Operational` event channel on the
   DeployR server and appends any new events to a durable CSV
   (`deployr-history.csv`). Safe to run repeatedly — it tracks a watermark
   (`RecordId`) so re-running never duplicates rows.

2. **`New-DeployRReport.ps1`** — the report builder.
   Reads that history CSV and produces:
   - a **daily counts CSV** (always the *full* collected history)
   - an **HTML report** scoped to a recent window (30 days by default),
     with bar charts, a figures table, or both

The two are independent. The collector must run often enough that the event
log doesn't wrap before you've captured it (see **Scheduling**, below). The
report can be regenerated any time, as often as you like, with no downside.

### Why counts, not paired start/end records

Each DeployR task sequence run logs a start event and (usually) an outcome
event, but they share no run ID — only a task sequence *definition* ID, which
is reused across every machine and every day. Pairing them up reliably would
mean inferring by client IP and timing, which breaks down when several
machines are rebuilt concurrently at a bench — the normal case in break/fix.
So this solution deliberately reports **simple per-day counts of each event
type**, which can't be mis-attributed, rather than per-run success/failure
records.

## Event types counted

| Event ID | Column       | Meaning                                   |
|---------:|--------------|--------------------------------------------|
| 17002    | `Started`    | Task sequence starting                     |
| 17003    | `Succeeded`  | Task sequence ended successfully           |
| 17004    | `Failed`     | Task sequence ended in failure             |
| 23001    | `AuthOk`     | Passcode authentication succeeded          |
| 23006    | `AuthFailed` | Passcode authentication failed             |

**Expected, not bugs:**
- `Started` will not exactly equal `Succeeded + Failed`. A VM that's powered
  off/reverted mid-sequence logs a start with no outcome, and a run spanning
  midnight logs its start and outcome on different calendar days.
- `AuthOk` will normally exceed `Started` — operators sometimes authenticate,
  reach the menu, and back out without deploying anything.

## Prerequisites

- Run on, or with network access to, the DeployR server.
- The account running the scripts needs **Event Log Readers** (or
  Administrator) membership on that server — nothing more. No DeployR
  passcode, login, or PowerShell module is required.
- PowerShell 5.1 or 7 both work (neither script uses the DeployR.Utility
  module).

## Usage

### First run / manual run

```powershell
# 1. Collect everything currently in the event log into a durable CSV
.\Export-DeployRAuditHistory.ps1 -HistoryPath C:\Reports\deployr-history.csv

# 2. Build the daily CSV and HTML report from it
.\New-DeployRReport.ps1 `
    -HistoryPath   C:\Reports\deployr-history.csv `
    -DailyCsvPath  C:\Reports\deployr-daily.csv `
    -HtmlPath      C:\Reports\deployr.html
```

Open `deployr.html` in a browser — it's a single self-contained file (no
internet access or external files needed), so it can also be emailed as an
attachment.

### Useful parameters on `New-DeployRReport.ps1`

| Parameter     | Default | Notes |
|---------------|---------|-------|
| `-ReportDays` | `30`    | Days shown in the **HTML report only**. The daily CSV always covers full history regardless of this value. Use `0` for full history in the HTML too. |
| `-Layout`     | `Charts` | `Charts` = bar charts + collapsed figures table. `Table` = figures only, no charts — stays readable at any range, so use this for long windows (e.g. a full year). `Both` = charts with the table expanded. |

Example — a full-history table instead of the default 30-day chart view:

```powershell
.\New-DeployRReport.ps1 `
    -HistoryPath  C:\Reports\deployr-history.csv `
    -DailyCsvPath C:\Reports\deployr-daily.csv `
    -HtmlPath     C:\Reports\deployr-full.html `
    -ReportDays 0 -Layout Table
```

## Scheduling

Set up both scripts as one scheduled task, run daily, one after the other:

```powershell
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument @'
-NoProfile -Command "
  & C:\Scripts\Export-DeployRAuditHistory.ps1 -HistoryPath C:\Reports\deployr-history.csv
  & C:\Scripts\New-DeployRReport.ps1 -HistoryPath C:\Reports\deployr-history.csv -DailyCsvPath C:\Reports\deployr-daily.csv -HtmlPath C:\Reports\deployr.html
"
'@
$trigger = New-ScheduledTaskTrigger -Daily -At 6am
Register-ScheduledTask -TaskName 'DeployR reporting' -Action $action -Trigger $trigger `
    -User 'DOMAIN\svc-deployr-report' -RunLevel Limited
```

The service account only needs Event Log Readers — no admin rights, no
DeployR credentials.

### Why the collector's schedule matters (and the report's doesn't)

`TwoPintSoftware-DeployR-Audit/Operational` is a circular log: once it fills,
old events are silently overwritten and gone for good. **Daily collection is
comfortably safe** at typical break/fix volumes — check your own headroom
with:

```powershell
Get-WinEvent -ListLog 'TwoPintSoftware-DeployR-Audit/Operational' |
    Select-Object MaximumSizeInBytes, FileSize, RecordCount, LogMode
```

Cheap extra insurance — raise the channel's size cap so you have a much wider
margin even if the task misses a run or two:

```powershell
wevtutil sl "TwoPintSoftware-DeployR-Audit/Operational" /ms:67108864   # 64 MB
```

The collector is idempotent, so there's no harm running it more often (e.g.
hourly) if you want fresher numbers during the day.

The **report script has no such deadline** — it only reads the CSV you've
already collected, so regenerating it late costs you nothing but freshness.

### Monitor the task itself

This design fails silently: if the scheduled task stops running, the CSV
simply stops growing and the HTML keeps rendering stale data without any
error. Worth alerting on either the collector's own output (`LastRecordId`,
`TotalRows`) or on `deployr-history.csv`'s `LastWriteTime` falling behind.

## Files produced

| File                    | Scope                          | Regenerated how |
|-------------------------|---------------------------------|------------------|
| `deployr-history.csv`   | Full history, one row per event | Appended to — never truncated |
| `deployr-daily.csv`     | Full history, one row per day   | Rebuilt from scratch each run (today's counts change through the day, so this can't be append-only) |
| `deployr.html`          | Last `-ReportDays` days          | Rebuilt from scratch each run |

## What this solution does *not* do

- **No per-device reporting.** The only device identifier in these events is
  client IP, which is a DHCP lease in WinPE and not a stable key over time.
  Deployed machines also have no identity at all until Autopilot enrols
  them — DeployR simply doesn't know which physical machine is which.
- **No task-sequence-name breakdown.** Counts are channel-wide, not broken
  down by which task sequence ran. (An earlier exploration built a
  `tsID`-to-name join via `Get-DeployRMetadata`, but that requires a DeployR
  passcode and was dropped as unnecessary for count-only reporting. Ask if
  you want it revisited.)
- **No success/failure pairing per run.** See "Why counts, not paired
  start/end records" above.

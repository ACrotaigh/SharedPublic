<#
.SYNOPSIS
    Incrementally collects DeployR audit events into a durable CSV store.

.DESCRIPTION
    Reads TwoPintSoftware-DeployR-Audit/Operational and appends any events newer
    than the last collected RecordId to a CSV history file. Designed to run on a
    schedule (hourly or daily). No DeployR authentication required -- this reads
    the Windows event log only.

    Why a separate collector rather than reporting straight off the event log:

      * The channel is a circular Operational log. It WILL eventually overwrite,
        taking your history with it. The CSV store is permanent.
      * RecordId is monotonic per channel, so it is a reliable watermark.
        Collection is idempotent: run it twice and nothing duplicates.
      * Reporting then runs over accumulated data and never has to worry about
        overlapping time windows.

    Reports read the CSV. See Get-DeployRActivityCount.ps1 for the summary, or
    just group the CSV directly.

.PARAMETER HistoryPath
    CSV history file. Created if absent.

.PARAMETER StatePath
    JSON file holding the watermark. Defaults to HistoryPath with a .state.json
    extension.

.PARAMETER ComputerName
    DeployR server to collect from. Defaults to local.

.EXAMPLE
    .\Export-DeployRAuditHistory.ps1 -HistoryPath C:\Reports\deployr-history.csv

.EXAMPLE
    # Scheduled hourly
    pwsh -NoProfile -File C:\Scripts\Export-DeployRAuditHistory.ps1 `
         -HistoryPath C:\Reports\deployr-history.csv

.NOTES
    LOG CLEARING: if the channel is cleared, RecordId restarts at 1 and would
    fall below the stored watermark, silently skipping everything thereafter.
    This is detected and the watermark resets, with a warning. Existing history
    is never rewritten, and any rows that overlap are de-duplicated on the
    combination of RecordId and TimeCreated.

    SCHEDULING: run at least twice as often as the channel could plausibly wrap.
    At break/fix volumes hourly is ample; daily is fine for a lab.

    PERMISSIONS: the task account needs to be in Event Log Readers (or
    Administrators) on the DeployR server.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HistoryPath,

    [string]$StatePath,

    [string]$ComputerName = $env:COMPUTERNAME,

    [string]$LogName = 'TwoPintSoftware-DeployR-Audit/Operational'
)

$ErrorActionPreference = 'Stop'

if (-not $StatePath) {
    $StatePath = [IO.Path]::ChangeExtension($HistoryPath, '.state.json')
}
foreach ($p in @($HistoryPath, $StatePath)) {
    $dir = Split-Path $p -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# --- Watermark ------------------------------------------------------------
$lastRecordId = 0
if (Test-Path $StatePath) {
    try   { $lastRecordId = [int64](Get-Content $StatePath -Raw | ConvertFrom-Json).LastRecordId }
    catch { Write-Warning "State file unreadable, starting from zero: $StatePath" }
}
Write-Verbose "Watermark: RecordId > $lastRecordId"

# --- Collect --------------------------------------------------------------
try {
    $events = Get-WinEvent -ComputerName $ComputerName -FilterHashtable @{ LogName = $LogName }
}
catch {
    if ($_.Exception.Message -match 'No events were found') {
        Write-Verbose 'Channel is empty.'
        $events = @()
    }
    else { throw }
}

$maxAvailable = ($events | Measure-Object RecordId -Maximum).Maximum
if ($lastRecordId -gt 0 -and $maxAvailable -and $maxAvailable -lt $lastRecordId) {
    Write-Warning "Highest RecordId ($maxAvailable) is below the watermark ($lastRecordId) -- the log appears to have been cleared. Resetting watermark; duplicate rows will be de-duplicated."
    $lastRecordId = 0
}

$fresh = @($events | Where-Object { $_.RecordId -gt $lastRecordId })
Write-Verbose "New events: $($fresh.Count)"

$rows = foreach ($e in $fresh) {
    $data = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) {
        if ($d.Name) { $data[$d.Name] = $d.'#text' }
    }
    [pscustomobject]@{
        TimeCreated = $e.TimeCreated.ToString('o')
        RecordId    = $e.RecordId
        EventId     = $e.Id
        Level       = $e.LevelDisplayName
        tsID        = $data['tsID']
        user        = $data['user']
        ip          = ($data['ip'] -replace '^::ffff:', '')
        Message     = ($e.Message -replace '\s+', ' ').Trim()
    }
}

# --- Merge and persist ----------------------------------------------------
if ($rows) {
    $existing = @()
    if (Test-Path $HistoryPath) { $existing = @(Import-Csv $HistoryPath) }

    $all = @($existing) + @($rows) |
        Sort-Object { [int64]$_.RecordId }, TimeCreated |
        Group-Object { "$($_.RecordId)|$($_.TimeCreated)" } |
        ForEach-Object { $_.Group[0] }

    $all | Export-Csv -Path $HistoryPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "History now holds $($all.Count) row(s)."
}

$newWatermark = if ($maxAvailable) { [int64]$maxAvailable } else { $lastRecordId }
[pscustomobject]@{ LastRecordId = $newWatermark; UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o') } |
    ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8

[pscustomobject]@{
    Collected    = @($rows).Count
    LastRecordId = $newWatermark
    HistoryPath  = $HistoryPath
    TotalRows    = if (Test-Path $HistoryPath) { @(Import-Csv $HistoryPath).Count } else { 0 }
}

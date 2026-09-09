<#
Canonical filename: Monitor-DeployRCommunityRelease.ps1
Baseline ID: DEPLOYR-RELEASE-MONITOR
Version: 1.0.0
Change: Accept Azure Automation Boolean inputs supplied as Boolean, SwitchParameter, numeric, or string values.
#>

#requires -Version 7.2
#requires -Modules Az.Accounts, Az.Automation

<#
.SYNOPSIS
Monitors the 2Pint DeployR Community release feed and sends email when a newer version is detected.

.DESCRIPTION
Production Azure Automation runbook that reads the DeployR Community JSON feed, selects either
an explicitly configured channel or the highest version across all channels, compares the release
with the version stored in Azure Automation, and sends an HTML notification through Microsoft
Graph using the Automation Account system-assigned managed identity.

The runbook includes transient-failure retries, exponential backoff, Retry-After support,
structured diagnostic logging, input validation, numeric version comparison, and state protection.
DeployRLastDetectedVersion is updated only after any required notification has been accepted by
Microsoft Graph.

CANONICAL FILE
Monitor-DeployRCommunityRelease.ps1

BASELINE ID
DEPLOYR-RELEASE-MONITOR

SCRIPT VERSION
1.0.0

REQUIRED AUTOMATION VARIABLES
DeployRLastDetectedVersion
DeployRNotificationRecipients
DeployRNotificationSender
DeployRReleaseChannel
DeployRReleaseJsonUri

.PARAMETER NotifyOnFirstRun
Sends a notification while establishing the initial baseline when DeployRLastDetectedVersion is
empty or 0.0.0.0. Accepts True, False, $True, $False, 1, or 0 in Azure Automation.

.PARAMETER ForceNotification
Sends a test notification even when the selected version equals the stored version. Accepts True,
False, $True, $False, 1, or 0. A forced test does not modify an existing baseline unless the detected
release is genuinely newer.

.PARAMETER MaximumRetryCount
Maximum attempts for transient HTTP operations. Default: 4.

.PARAMETER InitialRetryDelaySeconds
Initial retry delay in seconds. Default: 5. Exponential backoff is used unless Retry-After exists.

.NOTES
Authoring baseline: DEPLOYR-RELEASE-MONITOR/1.0.0
Runtime: PowerShell 7.2 or later
Identity: Azure Automation system-assigned managed identity
#>

[CmdletBinding()]
param(
    [Parameter()]
    [AllowNull()]
    [object]$NotifyOnFirstRun = $false,

    [Parameter()]
    [AllowNull()]
    [object]$ForceNotification = $false,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaximumRetryCount = 4,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$InitialRetryDelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptName = 'Monitor-DeployRCommunityRelease.ps1'
$script:ScriptVersion = '1.0.0'
$script:BaselineId = 'DEPLOYR-RELEASE-MONITOR'
$script:RunId = [guid]::NewGuid().Guid
$script:Stage = 'Initialisation'


function ConvertTo-BooleanParameter {
    <#
    .SYNOPSIS
    Converts Azure Automation runbook parameter input into a Boolean value.

    .DESCRIPTION
    The Azure Automation Test pane can submit Boolean-looking values as strings,
    including True, False, $True, $False, 1, and 0. Declaring these parameters as
    SwitchParameter can therefore fail during parameter binding before the runbook
    starts. This function normalises supported Boolean representations after binding.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($Value -is [System.Management.Automation.SwitchParameter]) {
        return [bool]$Value.IsPresent
    }

    if ($Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64]) {
        switch ([int64]$Value) {
            0 { return $false }
            1 { return $true }
            default {
                throw "Parameter '$ParameterName' accepts only 0 or 1 when supplied as a number."
            }
        }
    }

    $text = ([string]$Value).Trim()

    if ($text.StartsWith('$')) {
        $text = $text.Substring(1)
    }

    switch -Regex ($text) {
        '^(?i:true|1|yes|on)$'  { return $true }
        '^(?i:false|0|no|off)?$' { return $false }
        default {
            throw (
                "Parameter '$ParameterName' has unsupported Boolean value '$Value'. " +
                "Use True, False, `$True, `$False, 1, or 0."
            )
        }
    }
}

function Write-RunbookLog {
    <#
    .SYNOPSIS
    Writes structured logs without adding strings to a function's success-output pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [hashtable]$Data
    )

    $entry = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString('o')
        Level        = $Level
        RunId        = $script:RunId
        Stage        = $script:Stage
        Script       = $script:ScriptName
        Version      = $script:ScriptVersion
        Message      = $Message
    }

    if ($Data) {
        foreach ($key in $Data.Keys) {
            $entry[$key] = $Data[$key]
        }
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 8

    switch ($Level) {
        'INFO'  { Write-Verbose $json }
        'WARN'  { Write-Warning $json }
        'ERROR' { Write-Error $json -ErrorAction Continue }
    }
}

function Get-OptionalPropertyValue {
    <#
    .SYNOPSIS
    Safely reads an optional property while Set-StrictMode is enabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-HttpErrorDetails {
    <#
    .SYNOPSIS
    Safely extracts HTTP and exception details from an ErrorRecord.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $response = Get-OptionalPropertyValue -InputObject $exception -PropertyName 'Response'
    $headers = Get-OptionalPropertyValue -InputObject $response -PropertyName 'Headers'
    $statusCodeValue = Get-OptionalPropertyValue -InputObject $response -PropertyName 'StatusCode'
    $reasonPhraseValue = Get-OptionalPropertyValue -InputObject $response -PropertyName 'ReasonPhrase'

    $statusCode = $null
    if ($null -ne $statusCodeValue) {
        try { $statusCode = [int]$statusCodeValue } catch { $statusCode = $null }
    }

    $retryAfterSeconds = $null
    $requestId = $null

    if ($null -ne $headers) {
        try {
            $retryAfterRaw = $headers.GetValues('Retry-After') | Select-Object -First 1
            $parsedSeconds = 0

            if ([int]::TryParse([string]$retryAfterRaw, [ref]$parsedSeconds)) {
                $retryAfterSeconds = $parsedSeconds
            }
            else {
                $parsedDate = [datetimeoffset]::MinValue
                if ([datetimeoffset]::TryParse([string]$retryAfterRaw, [ref]$parsedDate)) {
                    $calculatedDelay = [math]::Ceiling(
                        ($parsedDate - [datetimeoffset]::UtcNow).TotalSeconds
                    )
                    if ($calculatedDelay -gt 0) {
                        $retryAfterSeconds = [int]$calculatedDelay
                    }
                }
            }
        }
        catch {
            $retryAfterSeconds = $null
        }

        foreach ($headerName in @('request-id', 'client-request-id', 'x-ms-request-id')) {
            try {
                $headerValue = $headers.GetValues($headerName) | Select-Object -First 1
                if ($headerValue) {
                    $requestId = [string]$headerValue
                    break
                }
            }
            catch {
                # Header is optional.
            }
        }
    }

    $responseBody = $null
    $errorDetails = $ErrorRecord.ErrorDetails
    $errorMessage = Get-OptionalPropertyValue -InputObject $errorDetails -PropertyName 'Message'

    if (-not [string]::IsNullOrWhiteSpace([string]$errorMessage)) {
        $responseBody = [string]$errorMessage
        if ($responseBody.Length -gt 2000) {
            $responseBody = $responseBody.Substring(0, 2000) + ' [truncated]'
        }
    }

    [pscustomobject]@{
        StatusCode        = $statusCode
        ReasonPhrase      = [string]$reasonPhraseValue
        RetryAfterSeconds = $retryAfterSeconds
        RequestId         = $requestId
        ResponseBody      = $responseBody
        ExceptionType     = if ($exception) { $exception.GetType().FullName } else { $null }
        ExceptionMessage  = if ($exception) { $exception.Message } else { $null }
    }
}

function Test-TransientFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Details
    )

    if ($Details.StatusCode -in @(408, 409, 425, 429, 500, 502, 503, 504)) {
        return $true
    }

    return $Details.ExceptionType -in @(
        'System.Net.Http.HttpRequestException',
        'System.Net.WebException',
        'System.TimeoutException',
        'System.Threading.Tasks.TaskCanceledException'
    )
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
    Executes a remote operation with limited retry handling for transient failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationName,

        [Parameter(Mandatory)]
        [scriptblock]$Operation
    )

    for ($attempt = 1; $attempt -le $MaximumRetryCount; $attempt++) {
        try {
            Write-RunbookLog -Level INFO -Message 'Starting remote operation.' -Data @{
                Operation = $OperationName
                Attempt   = $attempt
                Maximum   = $MaximumRetryCount
            }

            $result = & $Operation

            Write-RunbookLog -Level INFO -Message 'Remote operation completed.' -Data @{
                Operation = $OperationName
                Attempt   = $attempt
            }

            return $result
        }
        catch {
            $details = Get-HttpErrorDetails -ErrorRecord $_
            $isTransient = Test-TransientFailure -Details $details
            $isFinalAttempt = $attempt -ge $MaximumRetryCount

            $logData = @{
                Operation        = $OperationName
                Attempt          = $attempt
                Maximum          = $MaximumRetryCount
                IsTransient      = $isTransient
                StatusCode       = $details.StatusCode
                ReasonPhrase     = $details.ReasonPhrase
                RequestId        = $details.RequestId
                ExceptionType    = $details.ExceptionType
                ExceptionMessage = $details.ExceptionMessage
                ResponseBody     = $details.ResponseBody
            }

            if (-not $isTransient -or $isFinalAttempt) {
                Write-RunbookLog -Level ERROR -Message 'Remote operation failed and will not be retried.' -Data $logData
                throw
            }

            if ($details.RetryAfterSeconds -and $details.RetryAfterSeconds -gt 0) {
                $delaySeconds = [math]::Min($details.RetryAfterSeconds, 300)
                $delaySource = 'Retry-After'
            }
            else {
                $delaySeconds = [int][math]::Ceiling(
                    [math]::Min(
                        $InitialRetryDelaySeconds * [math]::Pow(2, $attempt - 1),
                        300
                    )
                )
                $delaySource = 'ExponentialBackoff'
            }

            $logData['DelaySeconds'] = $delaySeconds
            $logData['DelaySource'] = $delaySource
            Write-RunbookLog -Level WARN -Message 'Transient failure detected. Retrying after delay.' -Data $logData
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-RequiredAutomationVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        $value = Get-AutomationVariable -Name $Name
    }
    catch {
        throw "Unable to read Azure Automation variable '$Name'. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Azure Automation variable '$Name' is missing or empty."
    }

    return [string]$value
}

function ConvertTo-ReleaseVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Version '$Version' is not in the expected four-part numeric format."
    }

    $parsedVersion = $null
    if (-not [version]::TryParse($Version, [ref]$parsedVersion)) {
        throw "Version '$Version' is not a valid System.Version value."
    }

    return $parsedVersion
}

function Test-MailAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    try {
        $parsedAddress = [System.Net.Mail.MailAddress]::new($Address)
        return $parsedAddress.Address -eq $Address
    }
    catch {
        return $false
    }
}

function Get-DeployRCommunityRelease {
    <#
    .SYNOPSIS
    Retrieves and selects a release from the DeployR Community JSON feed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uri]$JsonUri,

        [Parameter(Mandatory)]
        [string]$ReleaseChannel
    )

    $manifest = Invoke-WithRetry -OperationName 'Retrieve DeployR release JSON' -Operation {
        Invoke-RestMethod `
            -Uri $JsonUri `
            -Method Get `
            -Headers @{
                Accept          = 'application/json'
                'Cache-Control' = 'no-cache'
                'User-Agent'    = 'AzureAutomation-DeployRCommunityMonitor/1.0.0'
            } `
            -TimeoutSec 60 `
            -ErrorAction Stop
    }

    if ([string]::IsNullOrWhiteSpace([string]$manifest.product)) {
        throw 'The release JSON does not contain a product property.'
    }

    if ([string]$manifest.product -ne 'deployrcommunity') {
        throw "Unexpected product '$($manifest.product)'. Expected 'deployrcommunity'."
    }

    if ($null -eq $manifest.channels) {
        throw 'The release JSON does not contain a channels object.'
    }

    $releases = @(
        foreach ($channelProperty in $manifest.channels.PSObject.Properties) {
            $channel = [string]$channelProperty.Name
            $data = $channelProperty.Value
            $version = [string]$data.version

            if ([string]::IsNullOrWhiteSpace($version)) {
                Write-RunbookLog -Level WARN -Message 'Channel has no version and was ignored.' -Data @{
                    Channel = $channel
                }
                continue
            }

            try {
                $parsedVersion = ConvertTo-ReleaseVersion -Version $version
            }
            catch {
                Write-RunbookLog -Level WARN -Message 'Channel has an invalid version and was ignored.' -Data @{
                    Channel = $channel
                    Version = $version
                    Error   = $_.Exception.Message
                }
                continue
            }

            $expectedArtifactName = "DeployRCommunity-$version.zip"
            $artifactProperty = $null

            if ($null -ne $data.artifacts) {
                $artifactProperty = $data.artifacts.PSObject.Properties |
                    Where-Object Name -eq $expectedArtifactName |
                    Select-Object -First 1
            }

            if ($null -eq $artifactProperty) {
                throw "Channel '$channel' does not contain expected artifact '$expectedArtifactName'."
            }

            $artifactUri = [uri]::new($JsonUri, [string]$artifactProperty.Value).AbsoluteUri
            $checksumsUri = if (-not [string]::IsNullOrWhiteSpace([string]$data.checksums)) {
                [uri]::new($JsonUri, [string]$data.checksums).AbsoluteUri
            }
            else {
                $null
            }

            [pscustomobject]@{
                Product        = [string]$manifest.product
                Channel        = $channel
                Version        = $version
                ParsedVersion  = $parsedVersion
                Timestamp      = [string]$data.timestamp
                BuildId        = [string]$data.build_id
                Commit         = [string]$data.commit
                ArtifactName   = $expectedArtifactName
                ArtifactUri    = $artifactUri
                ChecksumsUri   = $checksumsUri
                ReleaseJsonUri = $JsonUri.AbsoluteUri
            }
        }
    )

    if ($releases.Count -eq 0) {
        throw 'No valid DeployR Community releases were found.'
    }

    if ($ReleaseChannel -ieq 'Latest') {
        $selectedRelease = $releases |
            Sort-Object ParsedVersion -Descending |
            Select-Object -First 1
    }
    else {
        $selectedRelease = $releases |
            Where-Object Channel -ieq $ReleaseChannel |
            Select-Object -First 1
    }

    if ($null -eq $selectedRelease) {
        $availableChannels = ($releases.Channel | Sort-Object) -join ', '
        throw "Release channel '$ReleaseChannel' was not found. Available channels: $availableChannels."
    }

    return $selectedRelease
}

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
    Gets a Graph token using the connected Automation Account managed identity.
    #>
    [CmdletBinding()]
    param()

    $tokenResponse = Invoke-WithRetry -OperationName 'Acquire Microsoft Graph access token' -Operation {
        Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com' `
            -ErrorAction Stop
    }

    if ($tokenResponse.Token -is [securestring]) {
        $plainTextToken = [System.Net.NetworkCredential]::new(
            [string]::Empty,
            $tokenResponse.Token
        ).Password
    }
    else {
        $plainTextToken = [string]$tokenResponse.Token
    }

    if ([string]::IsNullOrWhiteSpace($plainTextToken)) {
        throw 'Microsoft Graph token acquisition returned an empty token.'
    }

    return $plainTextToken
}

function Send-DeployRReleaseNotification {
    <#
    .SYNOPSIS
    Submits the release notification through Microsoft Graph.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SenderAddress,

        [Parameter(Mandatory)]
        [string[]]$Recipients,

        [Parameter(Mandatory)]
        [pscustomobject]$Release,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PreviousVersion,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $token = Get-GraphAccessToken
    $previousDisplay = if ([string]::IsNullOrWhiteSpace($PreviousVersion)) {
        'No previous baseline'
    }
    else {
        [System.Net.WebUtility]::HtmlEncode($PreviousVersion)
    }

    $encodedVersion = [System.Net.WebUtility]::HtmlEncode($Release.Version)
    $encodedChannel = [System.Net.WebUtility]::HtmlEncode($Release.Channel)
    $encodedBuildId = [System.Net.WebUtility]::HtmlEncode($Release.BuildId)
    $encodedTimestamp = [System.Net.WebUtility]::HtmlEncode($Release.Timestamp)
    $encodedCommit = [System.Net.WebUtility]::HtmlEncode($Release.Commit)
    $encodedReason = [System.Net.WebUtility]::HtmlEncode($Reason)
    $encodedArtifactName = [System.Net.WebUtility]::HtmlEncode($Release.ArtifactName)
    $encodedArtifactUri = [System.Net.WebUtility]::HtmlEncode($Release.ArtifactUri)
    $encodedChecksumsUri = [System.Net.WebUtility]::HtmlEncode($Release.ChecksumsUri)
    $encodedFeedUri = [System.Net.WebUtility]::HtmlEncode($Release.ReleaseJsonUri)

    $checksumsRow = if ([string]::IsNullOrWhiteSpace($Release.ChecksumsUri)) {
        '<tr><td><strong>Checksums</strong></td><td>Not supplied</td></tr>'
    }
    else {
        "<tr><td><strong>Checksums</strong></td><td><a href='$encodedChecksumsUri'>$encodedChecksumsUri</a></td></tr>"
    }

    $htmlBody = @"
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#242424">
<h2 style="color:#0f6cbd">DeployR Community release detected</h2>
<p>The DeployR Community release monitor identified the following release.</p>
<table cellpadding="7" cellspacing="0" border="1" style="border-collapse:collapse;border-color:#d1d1d1">
<tr><td><strong>Previous version</strong></td><td>$previousDisplay</td></tr>
<tr><td><strong>Detected version</strong></td><td>$encodedVersion</td></tr>
<tr><td><strong>Channel</strong></td><td>$encodedChannel</td></tr>
<tr><td><strong>Build ID</strong></td><td>$encodedBuildId</td></tr>
<tr><td><strong>Release timestamp</strong></td><td>$encodedTimestamp</td></tr>
<tr><td><strong>Commit</strong></td><td>$encodedCommit</td></tr>
<tr><td><strong>Reason</strong></td><td>$encodedReason</td></tr>
<tr><td><strong>Download</strong></td><td><a href="$encodedArtifactUri">$encodedArtifactName</a></td></tr>
$checksumsRow
<tr><td><strong>Release feed</strong></td><td><a href="$encodedFeedUri">$encodedFeedUri</a></td></tr>
<tr><td><strong>Run ID</strong></td><td>$script:RunId</td></tr>
<tr><td><strong>Script version</strong></td><td>$script:ScriptVersion</td></tr>
</table>
<p>Review the release and validate it in the DeployR test environment before production deployment.</p>
</body>
</html>
"@

    $toRecipients = @(
        foreach ($recipient in $Recipients) {
            @{
                emailAddress = @{
                    address = $recipient
                }
            }
        }
    )

    $requestBody = @{
        message = @{
            subject = "DeployR Community release detected: $($Release.Version)"
            body = @{
                contentType = 'HTML'
                content     = $htmlBody
            }
            toRecipients = $toRecipients
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 10

    $encodedSender = [uri]::EscapeDataString($SenderAddress)
    $sendMailUri = "https://graph.microsoft.com/v1.0/users/$encodedSender/sendMail"

    Invoke-WithRetry -OperationName 'Submit notification to Microsoft Graph' -Operation {
        Invoke-RestMethod `
            -Uri $sendMailUri `
            -Method Post `
            -Headers @{
                Authorization              = "Bearer $token"
                'client-request-id'        = $script:RunId
                'return-client-request-id' = 'true'
            } `
            -ContentType 'application/json' `
            -Body $requestBody `
            -TimeoutSec 60 `
            -ErrorAction Stop | Out-Null
    } | Out-Null
}

$NotifyOnFirstRunEnabled = ConvertTo-BooleanParameter `
    -Value $NotifyOnFirstRun `
    -ParameterName 'NotifyOnFirstRun'

$ForceNotificationEnabled = ConvertTo-BooleanParameter `
    -Value $ForceNotification `
    -ParameterName 'ForceNotification'

try {
    Write-RunbookLog -Level INFO -Message 'Release monitor started.' -Data @{
        BaselineId               = $script:BaselineId
        ForceNotification        = $ForceNotificationEnabled
        NotifyOnFirstRun         = $NotifyOnFirstRunEnabled
        MaximumRetryCount        = $MaximumRetryCount
        InitialRetryDelaySeconds = $InitialRetryDelaySeconds
    }

    $script:Stage = 'Authenticate managed identity'
    Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

    $script:Stage = 'Read configuration'
    $releaseJsonUriText = Get-RequiredAutomationVariable -Name 'DeployRReleaseJsonUri'
    $releaseChannel = Get-RequiredAutomationVariable -Name 'DeployRReleaseChannel'
    $notificationSender = Get-RequiredAutomationVariable -Name 'DeployRNotificationSender'
    $notificationRecipientText = Get-RequiredAutomationVariable -Name 'DeployRNotificationRecipients'

    try {
        $lastDetectedVersion = [string](Get-AutomationVariable -Name 'DeployRLastDetectedVersion')
    }
    catch {
        throw "Unable to read Azure Automation variable 'DeployRLastDetectedVersion'. $($_.Exception.Message)"
    }

    $releaseJsonUri = $null
    if (-not [uri]::TryCreate($releaseJsonUriText, [UriKind]::Absolute, [ref]$releaseJsonUri)) {
        throw "DeployRReleaseJsonUri is not a valid absolute URI: '$releaseJsonUriText'."
    }

    if ($releaseJsonUri.Scheme -ne 'https') {
        throw 'DeployRReleaseJsonUri must use HTTPS.'
    }

    $recipients = @(
        $notificationRecipientText -split '[;,]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if (-not (Test-MailAddress -Address $notificationSender)) {
        throw "DeployRNotificationSender contains invalid address '$notificationSender'."
    }

    if ($recipients.Count -eq 0) {
        throw 'DeployRNotificationRecipients contains no valid recipient address.'
    }

    foreach ($recipient in $recipients) {
        if (-not (Test-MailAddress -Address $recipient)) {
            throw "DeployRNotificationRecipients contains invalid address '$recipient'."
        }
    }

    Write-RunbookLog -Level INFO -Message 'Configuration validated.' -Data @{
        ReleaseChannel = $releaseChannel
        JsonUri        = $releaseJsonUri.AbsoluteUri
        Sender         = $notificationSender
        RecipientCount = $recipients.Count
        StoredVersion  = $lastDetectedVersion
    }

    $script:Stage = 'Read and evaluate release feed'
    $selectedRelease = Get-DeployRCommunityRelease `
        -JsonUri $releaseJsonUri `
        -ReleaseChannel $releaseChannel

    Write-RunbookLog -Level INFO -Message 'Release selected.' -Data @{
        Channel   = $selectedRelease.Channel
        Version   = $selectedRelease.Version
        BuildId   = $selectedRelease.BuildId
        Timestamp = $selectedRelease.Timestamp
        Artifact  = $selectedRelease.ArtifactName
    }

    $script:Stage = 'Compare release state'
    $isInitialRun = [string]::IsNullOrWhiteSpace($lastDetectedVersion) -or
        $lastDetectedVersion -eq '0.0.0.0'

    $sendNotification = $ForceNotificationEnabled
    $updateStoredVersion = $false
    $notificationReason = if ($ForceNotificationEnabled) { 'Forced notification test' } else { $null }

    if ($isInitialRun) {
        $updateStoredVersion = $true

        if (-not $ForceNotificationEnabled) {
            $sendNotification = $NotifyOnFirstRunEnabled
            $notificationReason = 'Initial baseline established'
        }

        Write-RunbookLog -Level INFO -Message 'Initial baseline required.' -Data @{
            NewBaseline = $selectedRelease.Version
            WillNotify  = $sendNotification
        }
    }
    else {
        $storedVersion = ConvertTo-ReleaseVersion -Version $lastDetectedVersion

        if ($selectedRelease.ParsedVersion -gt $storedVersion) {
            $sendNotification = $true
            $updateStoredVersion = $true
            $notificationReason = 'A newer DeployR Community version was detected'

            Write-RunbookLog -Level INFO -Message 'Newer release detected.' -Data @{
                PreviousVersion = $lastDetectedVersion
                NewVersion      = $selectedRelease.Version
            }
        }
        elseif ($selectedRelease.ParsedVersion -eq $storedVersion) {
            Write-RunbookLog -Level INFO -Message 'No newer release detected.' -Data @{
                StoredVersion   = $lastDetectedVersion
                SelectedVersion = $selectedRelease.Version
                ForcedEmail     = $ForceNotificationEnabled
            }
        }
        else {
            Write-RunbookLog -Level WARN -Message 'Feed version is older than stored version. State will not be downgraded.' -Data @{
                StoredVersion   = $lastDetectedVersion
                SelectedVersion = $selectedRelease.Version
                ForcedEmail     = $ForceNotificationEnabled
            }
        }
    }

    if ($sendNotification) {
        $script:Stage = 'Send notification'
        Send-DeployRReleaseNotification `
            -SenderAddress $notificationSender `
            -Recipients $recipients `
            -Release $selectedRelease `
            -PreviousVersion $lastDetectedVersion `
            -Reason $notificationReason

        Write-RunbookLog -Level INFO -Message 'Microsoft Graph accepted the email request.' -Data @{
            Sender     = $notificationSender
            Recipients = ($recipients -join ', ')
            Version    = $selectedRelease.Version
        }
    }

    if ($updateStoredVersion) {
        $script:Stage = 'Update release state'

        # Set-AutomationVariable is local to the Automation job. It is intentionally not
        # wrapped in the HTTP retry function because it does not return an HTTP response.
        Set-AutomationVariable `
            -Name 'DeployRLastDetectedVersion' `
            -Value $selectedRelease.Version

        Write-RunbookLog -Level INFO -Message 'Stored release version updated.' -Data @{
            PreviousVersion = $lastDetectedVersion
            StoredVersion   = $selectedRelease.Version
        }
    }

    $script:Stage = 'Completed'
    Write-RunbookLog -Level INFO -Message 'Release monitor completed successfully.' -Data @{
        SelectedVersion = $selectedRelease.Version
        NotificationSent = $sendNotification
        StateUpdated      = $updateStoredVersion
    }
}
catch {
    $errorRecord = $_
    $details = Get-HttpErrorDetails -ErrorRecord $errorRecord

    Write-RunbookLog -Level ERROR -Message 'Release monitor failed.' -Data @{
        FailedStage      = $script:Stage
        StatusCode       = $details.StatusCode
        ReasonPhrase     = $details.ReasonPhrase
        RequestId        = $details.RequestId
        ExceptionType    = $details.ExceptionType
        ExceptionMessage = $details.ExceptionMessage
        ResponseBody     = $details.ResponseBody
        ScriptStackTrace = $errorRecord.ScriptStackTrace
    }

    throw
}
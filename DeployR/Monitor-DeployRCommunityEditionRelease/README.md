# DeployR Community Release Monitor

## Overview

`Monitor-DeployRCommunityRelease.ps1` is an Azure Automation PowerShell 7.2 runbook that monitors the 2Pint Software DeployR Community release feed and sends an email notification when a newer release is detected.

The runbook uses:

- Azure Automation for execution and scheduling
- A system-assigned managed identity for authentication
- Microsoft Graph `Mail.Send` application permission
- A shared mailbox as the notification sender
- Azure Automation variables for configuration and release-state tracking
- The structured DeployR Community JSON release feed rather than HTML scraping

The current validated script baseline is:

```text
Baseline ID: DEPLOYR-RELEASE-MONITOR
Version: 1.0.0
Canonical filename: Monitor-DeployRCommunityRelease.ps1
PowerShell runtime: 7.2
VS Code validation: No problems detected
```

## Solution flow

```text
Azure Automation schedule
        |
        v
DeployR Community JSON release feed
        |
        v
Select configured channel or latest version
        |
        v
Compare with DeployRLastDetectedVersion
        |
        +---- No newer version ----> Log result and finish
        |
        +---- Newer version -------> Send email with Microsoft Graph
                                      |
                                      v
                            Update stored version only
                            after successful submission
```

## Runbook functionality

The runbook performs the following operations:

1. Reads configuration from Azure Automation variables.
2. Validates the release feed URI, sender address, recipients, and stored version.
3. Authenticates to Azure using the Automation Account system-assigned managed identity.
4. Retrieves the DeployR Community release manifest:

   ```text
   https://releases.2pintsoftware.com/deployrcommunity/release.json
   ```

5. Validates that the manifest identifies the product as `deployrcommunity`.
6. Enumerates the available release channels.
7. Selects either:
   - a configured channel such as `1.3`; or
   - the highest published version when the channel is `Latest`.
8. Validates the expected package name:

   ```text
   DeployRCommunity-<version>.zip
   ```

9. Compares versions using `System.Version`, avoiding incorrect string-based version sorting.
10. Sends an HTML email through Microsoft Graph when a newer version is detected.
11. Updates `DeployRLastDetectedVersion` only after any required email submission succeeds.
12. Prevents a lower feed version from overwriting a higher stored version.
13. Retries transient HTTP failures using exponential backoff or `Retry-After` when available.
14. Writes structured diagnostic records containing the run ID, stage, HTTP status, request ID, exception type, and response body where available.

## Azure resources

The implementation requires the following deployment-specific values:

```text
Tenant/domain: <tenant-domain>
Automation Account: <AutomationAccountName>
Resource Group: <ResourceGroupName>
Runbook: DeployR-Monitor-PS7
Sender shared mailbox: <sender-mailbox@tenant-domain>
```

Replace the placeholder values above with the names used in the target environment.

## Prerequisites

Before deploying the runbook, ensure that the following are available:

- An Azure subscription
- An Azure Automation Account
- PowerShell 7.2 runbook support
- The `Az.Accounts` and `Az.Automation` modules in the runbook runtime
- A system-assigned managed identity enabled on the Automation Account
- A mailbox-enabled sender, such as a shared mailbox
- An administrator able to assign Microsoft Graph application permissions
- A recipient mailbox or distribution list for notifications

A managed identity allows the runbook to authenticate without storing a client secret or certificate in the code. Microsoft documents enabling the system-assigned identity from the Automation Account's **Identity** page and identifies its `principalId` as the service principal object ID used for permission assignments.

## Create or configure the Automation Account

1. Open **Azure portal**.
2. Go to **Automation Accounts**.
3. Open the existing account or create a new one.
4. For this implementation, select:

   ```text
   Networking: Public access enabled
   Private endpoint: Not required
   Runtime: PowerShell 7.2
   ```

   Public access is required for the cloud runbook to reach both the public 2Pint release feed and Microsoft Graph.

5. Open **Identity**.
6. Under **System assigned**, set **Status** to **On**.
7. Select **Save**.
8. Copy the **Object (principal) ID**.

A system-assigned managed identity is tied to the Automation Account and is represented in Microsoft Entra ID by a service principal with an object ID.

## Configure Microsoft Graph `Mail.Send`

### Permission model

The runbook calls:

```http
POST https://graph.microsoft.com/v1.0/users/{sender}/sendMail
```

The managed identity requires the Microsoft Graph **application permission**:

```text
Mail.Send
```

Microsoft Graph documents `Mail.Send` as the application permission for `POST /users/{id | userPrincipalName}/sendMail`. A successful request returns HTTP `202 Accepted` with no response body. Acceptance means Graph accepted the request, while Exchange Online completes the subsequent delivery processing.

### Where to run the permission-assignment commands

Run the following commands in **Azure Cloud Shell using PowerShell** or from an administrative PowerShell session with the Microsoft Graph PowerShell modules installed.

Do not run these commands inside the Automation runbook. They are one-time administrative setup commands.

### Assign `Mail.Send` to the managed identity

```powershell
$AutomationAccountName = '<AutomationAccountName>'
$ResourceGroupName = '<ResourceGroupName>'

$AutomationAccount = Get-AzAutomationAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $AutomationAccountName

$ManagedIdentityObjectId = $AutomationAccount.Identity.PrincipalId

$ManagedIdentityObjectId
```

Connect to Microsoft Graph with permission to read applications and assign app roles:

```powershell
Connect-MgGraph `
    -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All'
```

Locate the Automation Account managed identity:

```powershell
$ManagedIdentity = Get-MgServicePrincipal `
    -ServicePrincipalId $ManagedIdentityObjectId
```

Locate the Microsoft Graph service principal:

```powershell
$GraphServicePrincipal = Get-MgServicePrincipal `
    -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
```

Locate the `Mail.Send` application role:

```powershell
$MailSendRole = $GraphServicePrincipal.AppRoles |
    Where-Object {
        $_.Value -eq 'Mail.Send' -and
        $_.AllowedMemberTypes -contains 'Application'
    }

$MailSendRole |
    Select-Object Id, Value, DisplayName, AllowedMemberTypes
```

Create the app-role assignment:

```powershell
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $ManagedIdentity.Id `
    -PrincipalId $ManagedIdentity.Id `
    -ResourceId $GraphServicePrincipal.Id `
    -AppRoleId $MailSendRole.Id
```

Application permissions are implemented as app-role assignments to the client service principal. The assignment uses the client service-principal ID, the Microsoft Graph resource service-principal ID, and the selected app-role ID.

### Verify the permission

```powershell
Get-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $ManagedIdentity.Id |
    Where-Object {
        $_.ResourceDisplayName -eq 'Microsoft Graph'
    } |
    Select-Object `
        PrincipalDisplayName,
        ResourceDisplayName,
        AppRoleId
```

To verify that the assigned role ID is `Mail.Send`:

```powershell
$Assignments = Get-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $ManagedIdentity.Id

$Assignments |
    Where-Object {
        $_.ResourceId -eq $GraphServicePrincipal.Id -and
        $_.AppRoleId -eq $MailSendRole.Id
    }
```

The Microsoft Graph PowerShell SDK provides `Get-MgServicePrincipalAppRoleAssignment` for reading app-role assignments on a service principal.

### Sender mailbox

Configure a mailbox-enabled sender, for example:

```text
<sender-mailbox@tenant-domain>
```

This is a shared mailbox. The managed identity is not itself a mailbox, so the runbook obtains an application token and submits mail through the configured mailbox using the `/users/{sender}/sendMail` endpoint.

> **Security note:** `Mail.Send` application permission is broad. In a production tenant, apply the tenant's approved Exchange Online application-access scoping control so that the managed identity can send only through the intended mailbox. Validate the restriction separately before production use.

## Azure Automation variables

Create the following variables under:

```text
Automation Account
  > Shared Resources
  > Variables
```

### `DeployRReleaseJsonUri`

```text
Type: String
Encrypted: No
Value: https://releases.2pintsoftware.com/deployrcommunity/release.json
```

Purpose:

- Identifies the structured DeployR Community release feed.
- Must be an absolute HTTPS URI.

### `DeployRReleaseChannel`

Recommended value:

```text
Latest
```

Alternative fixed-channel value:

```text
1.3
```

Purpose:

- `Latest` selects the highest version across all channels and will detect a future channel such as `1.4`.
- A value such as `1.3` restricts monitoring to that channel.

### `DeployRLastDetectedVersion`

Initial value:

```text
0.0.0.0
```

Purpose:

- Stores the latest successfully processed release version.
- The first normal run replaces `0.0.0.0` with the selected current version without sending email, unless `NotifyOnFirstRun` is enabled.
- The value is updated only after any required notification has been accepted successfully.
- The runbook does not replace this value with an older feed version.

### `DeployRNotificationSender`

```text
Type: String
Encrypted: No
Value: <sender-mailbox@tenant-domain>
```

Purpose:

- Specifies the mailbox used in the Microsoft Graph `/users/{sender}/sendMail` request.
- Must be a valid mailbox-enabled address.

### `DeployRNotificationRecipients`

Example with one recipient:

```text
<recipient@tenant-domain>
```

Example with multiple recipients:

```text
<recipient@tenant-domain>;<team-recipient@tenant-domain>
```

Purpose:

- Specifies one or more notification recipients.
- Semicolons and commas are accepted as separators.
- Whitespace is removed and duplicate addresses are discarded.
- Every resulting address is validated before execution continues.

## Runbook parameters

### `NotifyOnFirstRun`

Controls whether an email is sent while the initial baseline is established.

Accepted Azure Automation values include:

```text
True
False
$True
$False
1
0
Yes
No
On
Off
```

Default behaviour when omitted or false:

```text
Store the current version as the baseline and do not send email.
```

### `ForceNotification`

Forces the runbook to execute the email path even when the detected version equals the stored version.

Use this to validate:

- Managed identity authentication
- Microsoft Graph access-token acquisition
- `Mail.Send` permission
- Sender mailbox validity
- Recipient formatting
- Email delivery

A forced notification does not change an existing baseline unless the selected release is genuinely newer.

### `MaximumRetryCount`

```text
Default: 4
Range: 1 to 10
```

Controls the maximum number of attempts for transient HTTP operations.

### `InitialRetryDelaySeconds`

```text
Default: 5
Range: 1 to 300
```

Controls the first exponential-backoff delay. When a service supplies a valid `Retry-After` header, that value is preferred, subject to the runbook's upper limit.

## Import and publish the runbook

1. Open the Automation Account.
2. Select **Runbooks**.
3. Select **Create a runbook** or open the existing runbook.
4. Use:

   ```text
   Runbook name: DeployR-Monitor-PS7
   Runbook type: PowerShell
   Runtime version: 7.2
   ```

5. Import or paste `Monitor-DeployRCommunityRelease.ps1`.
6. Select **Save**.
7. Use the **Test pane** to validate the draft.
8. Select **Publish** after validation succeeds.

Schedules and normal Azure Automation job starts execute the published runbook version, not an unpublished draft.

## Test plan

### Test 1: Initial baseline

Set:

```text
DeployRLastDetectedVersion = 0.0.0.0
```

Run with `NotifyOnFirstRun` and `ForceNotification` omitted or false.

Expected result:

- Job completes.
- Current release is detected.
- No email is sent.
- `DeployRLastDetectedVersion` changes to the detected version.

### Test 2: No release change

Run again with the stored version equal to the current feed version.

Expected result:

- Job completes.
- No email is sent.
- Stored version remains unchanged.

### Test 3: Forced email

Run with:

```text
ForceNotification = True
```

Expected result:

- Job completes.
- Email is sent from `<sender-mailbox@tenant-domain>`.
- Stored version remains unchanged when no newer release exists.

### Test 4: Invalid release URI

Temporarily set `DeployRReleaseJsonUri` to a nonexistent JSON path.

Expected result:

- Job fails.
- Structured error identifies the `Read and evaluate release feed` stage.
- HTTP `404` is classified as non-transient and is not retried.
- Stored version remains unchanged.
- No release notification is sent.

Restore the valid URI immediately after testing.

### Test 5: Invalid channel

Temporarily set:

```text
DeployRReleaseChannel = 999
```

Expected result:

- Job fails with the requested and available channels identified.
- Stored version remains unchanged.

Restore `Latest` or the intended fixed channel afterward.

### Test 6: Invalid sender

Temporarily configure a nonexistent sender and set:

```text
ForceNotification = True
```

Expected result:

- The runbook reaches the email path.
- Microsoft Graph returns an error such as `ErrorInvalidUser`.
- Job fails.
- Stored version remains unchanged.

Restore:

```text
DeployRNotificationSender = <sender-mailbox@tenant-domain>
```

### Test 7: Successful production-path test

Restore all valid values and run with `ForceNotification = True`.

Expected result:

- Job completes.
- Email is delivered.
- The sender's Sent Items contains the message where applicable.
- Existing baseline is unchanged if no newer release exists.

Microsoft Graph returns `202 Accepted` with no response body after accepting a valid `sendMail` request. Delivery continues through Exchange Online after that response.

## Schedule the runbook

Recommended schedule:

```text
Frequency: Daily
Time: 08:00
Time zone: Europe/Dublin, or the Azure portal equivalent that observes Irish daylight saving
```

To create the schedule:

1. Open the published runbook.
2. Select **Schedules**.
3. Select **Add a schedule**.
4. Create or select a daily schedule.
5. Leave `NotifyOnFirstRun` and `ForceNotification` false for normal operation.
6. Keep the default retry values unless there is a documented reason to change them.
7. Link the schedule to the runbook.

## Logging and troubleshooting

Each runbook execution creates an Azure Automation job. Review jobs under:

```text
Automation Account
  > Runbooks
  > DeployR-Monitor-PS7
  > Jobs
```

For a selected job, review:

- Output
- Errors
- Warnings
- All Logs
- Exception
- Source snapshot

The runbook's structured records include fields such as:

```text
TimestampUtc
Level
RunId
Stage
Script
Version
Message
Operation
Attempt
Maximum
StatusCode
ReasonPhrase
RequestId
ExceptionType
ExceptionMessage
ResponseBody
```

The `RunId` allows records from the same execution to be correlated.

For longer retention and KQL-based searching, configure Azure Automation diagnostic settings to forward **Job Logs** and **Job Streams** to a Log Analytics workspace. Microsoft documents that these diagnostic categories can be used for historical analysis and alerting.

## Configure a failed-job alert

A failed-job alert is separate from the runbook schedule. The alert evaluates Azure Automation metrics; it does not execute the runbook.

### Create the alert rule

1. Open the Automation Account.
2. Under **Monitoring**, select **Alerts**.
3. Select **Create** > **Alert rule**.
4. Confirm that the Automation Account is selected as the scope.
5. Under **Condition**, select **Add condition**.
6. Select the **Total Jobs** metric.
7. Filter the metric using these dimensions:

   ```text
   Runbook Name = DeployR-Monitor-PS7
   Status = Failed
   ```

8. Configure the threshold:

   ```text
   Aggregation: Total
   Operator: Greater than
   Threshold: 0
   Evaluation frequency: 15 minutes
   Lookback period: 1 hour
   ```

9. Under **Actions**, create or select an Action Group.
10. Add an email notification to a monitored recipient or team address.
11. Suggested rule name:

    ```text
    DeployR-Monitor-PS7 - Failed Job
    ```

12. Suggested severity:

    ```text
    Severity 2 - Warning
    ```

13. Enable automatic resolution and enable the rule when created.

Azure Automation exposes the `Total Jobs` metric with `Runbook` and `Status` dimensions. Microsoft recommends filtering by the specific runbook and the `Failed` status to avoid alerts from unrelated or hidden runbooks.

The evaluation frequency controls how often Azure Monitor checks the metric. It does **not** cause the runbook to execute every 15 minutes. Azure Monitor defines **Check every** as the alert evaluation frequency and **Lookback period** as the aggregation window.

### Test the alert

1. Ensure the alert rule and Action Group are enabled.
2. Temporarily configure an invalid release JSON path.
3. Start the published runbook.
4. Confirm the job status becomes **Failed**.
5. Confirm the alert appears under **Azure Monitor** > **Alerts**.
6. Confirm the Action Group email arrives.
7. Restore the valid JSON URI.
8. Run the published runbook again and confirm successful completion.
9. Verify that `DeployRLastDetectedVersion` was not changed by the failed test.

## Common failure scenarios

### `ErrorInvalidUser`

Example:

```text
The requested user 'user@invalid.example' is invalid.
```

Cause:

- The configured sender does not resolve to a valid mailbox.

Resolution:

- Restore `DeployRNotificationSender` to a valid mailbox.
- Use `ForceNotification = True` to retest the email path.

### HTTP 404 from the release feed

Cause:

- Incorrect JSON URI or nonexistent object path.

Expected runbook behaviour:

- Classify as non-transient.
- Do not retry.
- Fail the job.
- Preserve `DeployRLastDetectedVersion`.

### No email on first run

This is expected when:

```text
DeployRLastDetectedVersion = 0.0.0.0
NotifyOnFirstRun = False
```

The first run establishes the baseline only.

### Completed job but no email

Check whether the logic required an email:

- No newer release and `ForceNotification = False`: no email is expected.
- Initial baseline and `NotifyOnFirstRun = False`: no email is expected.

If an email should have been sent:

- Review the job's `Send notification` stage.
- Check the recipient's Inbox and Junk Email.
- Check the sender shared mailbox Sent Items and Inbox for a non-delivery report.
- Use Exchange Online message trace.

## Security considerations

- Do not store passwords, client secrets, certificates, or Graph tokens in the script.
- Do not write Graph access tokens or authorization headers to job logs.
- Restrict the managed identity's mailbox access using the approved Exchange Online application-access model.
- Send failure alerts to a mailbox or team address independent of the runbook's sender where possible.
- Review the `Mail.Send` role assignment periodically.
- Treat the Azure Automation variable names as a stable configuration contract.
- Preserve the canonical filename and baseline ID during future code changes.

## Reference links

- [Enable a system-assigned managed identity for Azure Automation](https://learn.microsoft.com/en-us/azure/automation/quickstarts/enable-managed-identity)
- [Use a system-assigned managed identity with Azure Automation](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
- [Microsoft Graph `sendMail`](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
- [Assign an app role to a service principal](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0)
- [Monitor Azure Automation runbooks with metric alerts](https://learn.microsoft.com/en-us/azure/automation/automation-alert-metric)
- [Forward Azure Automation job data to Azure Monitor Logs](https://learn.microsoft.com/en-us/azure/automation/automation-manage-send-joblogs-log-analytics)
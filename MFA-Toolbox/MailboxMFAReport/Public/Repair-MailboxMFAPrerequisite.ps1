#Requires -Version 5.1

function Repair-MailboxMFAPrerequisite {
    <#
    .SYNOPSIS
    Remediates Managed Folder Assistant prerequisites. This cmdlet writes to the tenant.

    .DESCRIPTION
    Performs the tenant changes that v0.10 carried out as a side effect of running a report:
    provisioning archives, enabling auto-expanding archiving, creating retention tags, creating or
    updating a retention policy, and assigning that policy to mailboxes.

    Every action is opt-in by its own switch, and the cmdlet refuses to run without at least one.
    There is deliberately NO default for -RetentionPolicyName; v0.10 defaulted it to
    'Default MRM Policy', which meant the default code path modified the tenant's built-in policy.

    Retention tags are described by a full specification rather than a bare name. v0.10 accepted
    names and hardcoded every created tag as All / MoveToArchive / 365 days at the call site, giving
    the caller no control over what was being created in their tenant.

    .PARAMETER Users
    Mailbox identities to remediate. Accepts pipeline input, including Get-MailboxMFAReadiness
    output (the User property binds by name).

    .PARAMETER EnableArchive
    Provisions the archive mailbox where it is missing.

    .PARAMETER EnableAutoExpandingArchive
    Enables auto-expanding archiving. IRREVERSIBLE: it cannot be disabled once enabled. The
    confirmation prompt states this.

    .PARAMETER RetentionPolicyName
    Retention policy to create, update, and optionally assign. Supplying this is what enables the
    retention work; there is no default.

    .PARAMETER RetentionTag
    Retention tag specifications to ensure exist and are linked to -RetentionPolicyName. Each entry
    is a hashtable requiring Name, Type, RetentionAction, and AgeLimitForRetention, for example:
      @{ Name = 'Contoso 2 year archive'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 730 }

    .PARAMETER AssignPolicyToMailbox
    Assigns -RetentionPolicyName to each mailbox. Separate from policy creation because reassigning
    a policy on a mailbox that already has one is a materially different act from creating a policy.

    .PARAMETER SkipGraphChecks
    Skips Microsoft Graph connectivity validation during preflight.

    .PARAMETER OutputPath
    Directory for a CSV record of the actions taken. Omit to return results without writing files.

    .PARAMETER LogPath
    Optional transcript path.

    .EXAMPLE
    Repair-MailboxMFAPrerequisite -Users user@contoso.com -EnableArchive -WhatIf

    Previews archive provisioning without changing anything.

    .EXAMPLE
    (Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt)).Results |
        Where-Object SkipReason -eq 'NoArchive' |
        Repair-MailboxMFAPrerequisite -EnableArchive

    Remediates only the mailboxes the readiness report proved were missing an archive.
    Get-MailboxMFAReadiness returns a run object, so the per-mailbox records come from .Results.

    .EXAMPLE
    Repair-MailboxMFAPrerequisite -Users user@contoso.com `
        -RetentionPolicyName 'Contoso MRM Policy' `
        -RetentionTag @{ Name = 'Contoso 2 year archive'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 730 } `
        -AssignPolicyToMailbox

    .NOTES
    Requires Exchange Online PowerShell with permission for the requested operations. Run with
    -WhatIf first; retention configuration changes are tenant-wide in effect.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('UserPrincipalName', 'Identity', 'PrimarySmtpAddress', 'User')]
        [string[]]$Users,

        [Parameter()]
        [switch]$EnableArchive,

        [Parameter()]
        [switch]$EnableAutoExpandingArchive,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RetentionPolicyName,

        [Parameter()]
        [hashtable[]]$RetentionTag,

        [Parameter()]
        [switch]$AssignPolicyToMailbox,

        [Parameter()]
        [switch]$SkipGraphChecks,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$LogPath
    )

    begin {
        $inputUsers = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($user in $Users) {
            if (-not [string]::IsNullOrWhiteSpace($user)) { $inputUsers.Add($user.Trim()) }
        }
    }

    end {
        $doRetention = -not [string]::IsNullOrWhiteSpace($RetentionPolicyName)

        # Checked BEFORE the "nothing requested" guard: supplying -RetentionTag
        # without a policy name is a specific mistake and deserves a specific
        # message, not the generic one.
        if (($RetentionTag -or $AssignPolicyToMailbox) -and -not $doRetention) {
            Write-Error '-RetentionTag and -AssignPolicyToMailbox require -RetentionPolicyName. There is deliberately no default policy name, because defaulting it would target the tenant built-in policy.'
            return
        }

        if (-not ($EnableArchive -or $EnableAutoExpandingArchive -or $doRetention)) {
            Write-Error 'No remediation was requested. Supply -EnableArchive, -EnableAutoExpandingArchive, and/or -RetentionPolicyName.'
            return
        }

        $tagSpecifications = @()
        if ($RetentionTag) {
            try {
                $tagSpecifications = @(ConvertTo-MFAReportTagSpecification -Specification $RetentionTag)
            }
            catch {
                Write-Error $_.Exception.Message
                return
            }
        }

        $session = Start-MFAReportSession `
            -Users $inputUsers `
            -LogPath $LogPath `
            -SkipGraphChecks:$SkipGraphChecks `
            -SkipRetentionPolicyTriggerValidation `
            -RequireArchiveRepair:($EnableArchive -or $EnableAutoExpandingArchive) `
            -RequireRetentionRepair:$doRetention

        if (-not $session.IsReady) { return }

        try {
            # Tag and policy work is tenant-scoped, so it happens ONCE per run
            # rather than once per mailbox as it did in v0.10.
            $sharedActions = [System.Collections.Generic.List[string]]::new()

            if ($doRetention) {
                foreach ($specification in $tagSpecifications) {
                    $sharedActions.Add((Repair-MFAReportRetentionTag -TagSpecification $specification -Cmdlet $PSCmdlet))
                }

                foreach ($action in (Repair-MFAReportRetentionPolicy -PolicyName $RetentionPolicyName `
                        -TagNames @($tagSpecifications | ForEach-Object { $_.Name }) -Cmdlet $PSCmdlet)) {
                    $sharedActions.Add($action)
                }

                foreach ($action in $sharedActions) {
                    Write-Information $action -InformationAction Continue
                }
            }

            $results = [System.Collections.Generic.List[object]]::new()
            $index = 0

            foreach ($user in $session.Users) {
                $index++
                Write-Progress -Activity 'Repairing Managed Folder Assistant prerequisites' `
                    -Status "$index of $($session.Users.Count): $user" `
                    -PercentComplete (($index / $session.Users.Count) * 100)

                $actions = [System.Collections.Generic.List[string]]::new()
                $mailbox = $null

                try {
                    $mailbox = Get-Mailbox -Identity $user -ErrorAction Stop
                }
                catch {
                    $results.Add([PSCustomObject]@{
                        RunId    = $session.RunId
                        User     = $user
                        Status   = 'Failed'
                        Actions  = "MailboxLookupFailed:$($_.Exception.Message)"
                    })
                    continue
                }

                $identity = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'UserPrincipalName')
                if ([string]::IsNullOrWhiteSpace($identity)) { $identity = $user }

                if ($EnableArchive) {
                    $actions.Add((Repair-MFAReportArchive -Identity $identity -Mailbox $mailbox -Cmdlet $PSCmdlet))
                    # Re-read so the auto-expanding check sees the new archive state.
                    $mailbox = Get-Mailbox -Identity $identity -ErrorAction SilentlyContinue
                }

                if ($EnableAutoExpandingArchive -and $mailbox) {
                    $actions.Add((Repair-MFAReportAutoExpandingArchive -Identity $identity -Mailbox $mailbox -Cmdlet $PSCmdlet))
                }

                if ($AssignPolicyToMailbox -and $mailbox) {
                    $actions.Add((Repair-MFAReportMailboxPolicyAssignment -Identity $identity -Mailbox $mailbox `
                        -PolicyName $RetentionPolicyName -Cmdlet $PSCmdlet))
                }

                $failed = @($actions | Where-Object { $_ -match 'Failed:' })
                $results.Add([PSCustomObject]@{
                    RunId   = $session.RunId
                    User    = $identity
                    Status  = $(if ($failed.Count -gt 0) { 'Failed' } else { 'Completed' })
                    Actions = ($actions -join '; ')
                })
            }

            Write-Progress -Activity 'Repairing Managed Folder Assistant prerequisites' -Completed
            $session.Results = @($results)

            if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
                $session.OutputPath = $OutputPath
                Initialize-MFAReportOutputDirectory -Path $OutputPath -Confirm:$false
                $path = Join-Path $OutputPath "MFARepair_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                $written = Export-MFAReportArtifact -InputObject @($results) -Path $path
                if ($written) { Write-Information "Repair report saved to $written" -InformationAction Continue }
            }

            $session.ExportCompleted = $true

            return [PSCustomObject]@{
                RunId         = $session.RunId
                SharedActions = @($sharedActions)
                Results       = @($results)
                Summary       = [PSCustomObject]@{
                    RunId     = $session.RunId
                    Total     = @($results).Count
                    Completed = @($results | Where-Object { $_.Status -eq 'Completed' }).Count
                    Failed    = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
                }
            }
        }
        finally {
            Stop-MFAReportSession -Session $session
        }
    }
}

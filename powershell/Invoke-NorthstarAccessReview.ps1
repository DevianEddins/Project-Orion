<#
.SYNOPSIS
    Processes approved Northstar access-review decisions.

.DESCRIPTION
    Validates access-review decisions, preserves approved access, and removes
    group membership only for rows explicitly marked Revoke.

    Supports -WhatIf for safe preview and blocks protected accounts and groups.

.NOTES
    Project: Project Orion
    Organization: Northstar Aerospace Systems
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param (
    [Parameter()]
    [string]$DecisionPath = ".\data\access-review-decisions.csv",

    [Parameter()]
    [string]$ResultPath = ".\reports\access-review-remediation.csv",

    [Parameter()]
    [string]$LogPath = ".\logs\access-review-remediation.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory -ErrorAction Stop

$ProtectedAccounts = @(
    "Administrator",
    "krbtgt"
)

$ProtectedGroups = @(
    "Domain Users",
    "Domain Admins",
    "Enterprise Admins",
    "Schema Admins",
    "Administrators",
    "Account Operators",
    "Server Operators",
    "Backup Operators",
    "Print Operators",
    "Group Policy Creator Owners"
)

$Results = [System.Collections.Generic.List[object]]::new()
$ProcessingDate = Get-Date

function Write-OrionLog {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    Write-Host $entry
    Add-Content -Path $LogPath -Value $entry
}

function Add-ProcessingResult {
    param (
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $Results.Add(
        [PSCustomObject]@{
            ProcessingDate    = $ProcessingDate.ToString("yyyy-MM-dd HH:mm:ss")
            ReviewCampaign    = $Row.ReviewCampaign
            ReviewID          = $Row.ReviewID
            SamAccountName    = $Row.SamAccountName
            DisplayName       = $Row.DisplayName
            Department        = $Row.Department
            GroupName         = $Row.GroupName
            AccessType        = $Row.AccessType
            RiskLevel         = $Row.RiskLevel
            Decision          = $Row.Decision
            Reviewer          = $Row.Reviewer
            ReviewerComments  = $Row.ReviewerComments
            ReviewDate        = $Row.ReviewDate
            ProcessingStatus  = $Status
            ProcessingDetails = $Details
        }
    )
}

$ResultDirectory = Split-Path -Path $ResultPath -Parent
$LogDirectory = Split-Path -Path $LogPath -Parent

if ($ResultDirectory -and -not (Test-Path -LiteralPath $ResultDirectory)) {
    New-Item -Path $ResultDirectory -ItemType Directory -Force | Out-Null
}

if ($LogDirectory -and -not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

Set-Content -Path $LogPath -Value ""

Write-OrionLog "Starting Northstar access-review processing."
Write-OrionLog "Decision file: $DecisionPath"

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    Write-OrionLog -Level "ERROR" -Message "Decision file was not found."
    throw "Decision file not found: $DecisionPath"
}

$Rows = @(Import-Csv -LiteralPath $DecisionPath)

if ($Rows.Count -eq 0) {
    throw "The decision file contains no rows."
}

$RequiredColumns = @(
    "ReviewID",
    "SamAccountName",
    "DisplayName",
    "Department",
    "GroupName",
    "AccessType",
    "RiskLevel",
    "Decision",
    "Reviewer",
    "ReviewerComments",
    "ReviewDate"
)

$AvailableColumns = @($Rows[0].PSObject.Properties.Name)
$MissingColumns = @($RequiredColumns | Where-Object { $_ -notin $AvailableColumns })

if ($MissingColumns.Count -gt 0) {
    throw "Missing required CSV column(s): $($MissingColumns -join ', ')"
}

$DecidedRows = @(
    $Rows | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.Decision)
    }
)

if ($DecidedRows.Count -eq 0) {
    throw "No completed Approve or Revoke decisions were found."
}

Write-OrionLog -Message "Found $($DecidedRows.Count) completed decision(s)."

foreach ($Row in $DecidedRows) {
    $Decision = ([string]$Row.Decision).Trim()
    $Username = ([string]$Row.SamAccountName).Trim()
    $GroupName = ([string]$Row.GroupName).Trim()
    $Reviewer = ([string]$Row.Reviewer).Trim()
    $Comments = ([string]$Row.ReviewerComments).Trim()
    $ReviewDate = ([string]$Row.ReviewDate).Trim()

    Write-OrionLog "Processing '$Decision' for '$Username' and '$GroupName'."

    if ($Decision -notin @("Approve", "Revoke")) {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Validation Failed" `
            -Details "Decision must be Approve or Revoke."

        Write-OrionLog -Level "WARNING" -Message "Invalid decision for '$Username'."
        continue
    }

    if (
        [string]::IsNullOrWhiteSpace($Reviewer) -or
        [string]::IsNullOrWhiteSpace($Comments) -or
        [string]::IsNullOrWhiteSpace($ReviewDate)
    ) {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Validation Failed" `
            -Details "Reviewer, reviewer comments, and review date are required."

        Write-OrionLog -Level "WARNING" -Message "Incomplete review metadata for '$Username'."
        continue
    }

    if ($Decision -eq "Approve") {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Approved - Retained" `
            -Details "Reviewer confirmed that access remains required."

        Write-OrionLog `
            -Level "SUCCESS" `
            -Message "Approved access retained for '$Username' in '$GroupName'."

        continue
    }

    if ($Username -in $ProtectedAccounts) {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Blocked" `
            -Details "Protected account cannot be modified by this workflow."

        Write-OrionLog -Level "WARNING" -Message "Blocked protected account '$Username'."
        continue
    }

    if ($GroupName -in $ProtectedGroups) {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Blocked" `
            -Details "Protected group cannot be removed by this workflow."

        Write-OrionLog -Level "WARNING" -Message "Blocked protected group '$GroupName'."
        continue
    }

    try {
        $User = Get-ADUser `
            -Identity $Username `
            -Properties MemberOf `
            -ErrorAction Stop

        $Group = Get-ADGroup `
            -Identity $GroupName `
            -ErrorAction Stop
    }
    catch {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Failed" `
            -Details $_.Exception.Message

        Write-OrionLog `
            -Level "ERROR" `
            -Message "Could not resolve '$Username' or '$GroupName'."

        continue
    }

    if ($User.MemberOf -notcontains $Group.DistinguishedName) {
        Add-ProcessingResult `
            -Row $Row `
            -Status "No Change Required" `
            -Details "User is not a direct member of the selected group."

        Write-OrionLog `
            -Level "WARNING" `
            -Message "'$Username' is not a direct member of '$GroupName'."

        continue
    }

    $Target = "$Username -> $GroupName"

    if ($PSCmdlet.ShouldProcess($Target, "Remove approved group access")) {
        try {
            Remove-ADGroupMember `
                -Identity $Group `
                -Members $User `
                -Confirm:$false `
                -ErrorAction Stop

            Add-ProcessingResult `
                -Row $Row `
                -Status "Revoked" `
                -Details "Approved access revocation completed successfully."

            Write-OrionLog `
                -Level "SUCCESS" `
                -Message "Removed '$Username' from '$GroupName'."
        }
        catch {
            Add-ProcessingResult `
                -Row $Row `
                -Status "Failed" `
                -Details $_.Exception.Message

            Write-OrionLog `
                -Level "ERROR" `
                -Message "Failed to revoke '$GroupName' from '$Username'."
        }
    }
    else {
        Add-ProcessingResult `
            -Row $Row `
            -Status "Preview - Would Revoke" `
            -Details "WhatIf preview; no Active Directory change was performed."

        Write-OrionLog `
            -Message "Previewed removal of '$Username' from '$GroupName'."
    }
}

$Results |
    Export-Csv `
        -Path $ResultPath `
        -NoTypeInformation `
        -Encoding UTF8

$ApprovedCount = @($Results | Where-Object ProcessingStatus -eq "Approved - Retained").Count
$RevokedCount = @($Results | Where-Object ProcessingStatus -eq "Revoked").Count
$PreviewCount = @($Results | Where-Object ProcessingStatus -eq "Preview - Would Revoke").Count
$BlockedCount = @($Results | Where-Object ProcessingStatus -eq "Blocked").Count
$FailedCount = @($Results | Where-Object ProcessingStatus -in @("Failed", "Validation Failed")).Count

Write-OrionLog `
    -Level "SUCCESS" `
    -Message "Processing results exported to '$ResultPath'."

Write-Host ""
Write-Host "========================================"
Write-Host " Northstar Access Review Results"
Write-Host "========================================"
Write-Host "Decisions processed : $($DecidedRows.Count)"
Write-Host "Approved/retained   : $ApprovedCount"
Write-Host "Revoked             : $RevokedCount"
Write-Host "Previewed revokes   : $PreviewCount"
Write-Host "Blocked             : $BlockedCount"
Write-Host "Failed              : $FailedCount"
Write-Host "Result path         : $ResultPath"
Write-Host "Log path            : $LogPath"
Write-Host ""

$Results |
    Select-Object SamAccountName,GroupName,Decision,ProcessingStatus |
    Format-Table -AutoSize
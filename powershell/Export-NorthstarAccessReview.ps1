<#
.SYNOPSIS
    Exports Active Directory access for a Northstar access-certification review.

.DESCRIPTION
    Creates one review row for each direct security-group entitlement assigned
    to an in-scope user. The output includes identity information, manager,
    entitlement classification, risk level, and blank reviewer-decision fields.

    This script is read-only and does not modify Active Directory.

.NOTES
    Project: Project Orion
    Organization: Northstar Aerospace Systems
    Domain: ad.northstar.local
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ReportPath = ".\reports\access-review.csv",

    [Parameter()]
    [string]$LogPath = ".\logs\access-review-export.log",

    [Parameter()]
    [switch]$IncludeDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory -ErrorAction Stop

# -------------------------------------------------------------------
# Environment configuration
# -------------------------------------------------------------------

$DomainDN = "DC=ad,DC=northstar,DC=local"
$PeopleOU = "OU=People,OU=Northstar,$DomainDN"

$DepartmentGroups = @(
    "GG_Engineering",
    "GG_Finance",
    "GG_HumanResources",
    "GG_InformationTechnology",
    "GG_Contractors",
    "GG_Executive",
    "GG_Legal",
    "GG_Operations",
    "GG_Sales",
    "GG_Support"
)

$BaselineGroups = @(
    "GG_VPN_Users",
    "GG_M365_Users",
    "GG_FileShare_Users"
)

$PrivilegedGroups = @(
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

$ExportDate = Get-Date
$ReviewCampaign = "Northstar Access Review - $($ExportDate.ToString('yyyy-MM'))"
$ReviewRows = [System.Collections.Generic.List[object]]::new()
$ManagerCache = @{}

# -------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------

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

function Get-ManagerDetails {
    param (
        [Parameter()]
        [AllowEmptyString()]
        [string]$ManagerDN
    )

    if ([string]::IsNullOrWhiteSpace($ManagerDN)) {
        return [PSCustomObject]@{
            Name              = ""
            SamAccountName    = ""
            UserPrincipalName = ""
        }
    }

    if ($ManagerCache.ContainsKey($ManagerDN)) {
        return $ManagerCache[$ManagerDN]
    }

    try {
        $manager = Get-ADUser `
            -Identity $ManagerDN `
            -Properties UserPrincipalName `
            -ErrorAction Stop

        $details = [PSCustomObject]@{
            Name              = $manager.Name
            SamAccountName    = $manager.SamAccountName
            UserPrincipalName = $manager.UserPrincipalName
        }
    }
    catch {
        Write-OrionLog `
            -Level "WARNING" `
            -Message "Could not resolve manager '$ManagerDN': $($_.Exception.Message)"

        $details = [PSCustomObject]@{
            Name              = ""
            SamAccountName    = ""
            UserPrincipalName = ""
        }
    }

    $ManagerCache[$ManagerDN] = $details
    return $details
}

function Get-EntitlementClassification {
    param (
        [Parameter(Mandatory)]
        [string]$GroupName
    )

    if ($GroupName -in $PrivilegedGroups) {
        return "Privileged"
    }

    if ($GroupName -in $DepartmentGroups) {
        return "Department"
    }

    if ($GroupName -in $BaselineGroups) {
        return "Baseline"
    }

    return "Other"
}

function Get-EntitlementRisk {
    param (
        [Parameter(Mandatory)]
        [string]$Classification
    )

    switch ($Classification) {
        "Privileged" { return "Critical" }
        "Other"      { return "High" }
        "Department" { return "Medium" }
        "Baseline"   { return "Low" }
        default      { return "Medium" }
    }
}

# -------------------------------------------------------------------
# Prepare output directories
# -------------------------------------------------------------------

$ReportDirectory = Split-Path -Path $ReportPath -Parent
$LogDirectory = Split-Path -Path $LogPath -Parent

if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
    New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null
}

if ($LogDirectory -and -not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

Set-Content -Path $LogPath -Value ""

Write-OrionLog "Starting Northstar access-review export."
Write-OrionLog "Review campaign: $ReviewCampaign"
Write-OrionLog "Review scope: $PeopleOU"

# -------------------------------------------------------------------
# Retrieve users
# -------------------------------------------------------------------

if ($IncludeDisabled) {
    $UserFilter = "*"
    Write-OrionLog "Including enabled and disabled accounts."
}
else {
    $UserFilter = "Enabled -eq 'True'"
    Write-OrionLog "Including enabled accounts only."
}

try {
    $Users = @(
        Get-ADUser `
            -Filter $UserFilter `
            -SearchBase $PeopleOU `
            -Properties Department,
                        Title,
                        Manager,
                        UserPrincipalName,
                        MemberOf,
                        Enabled
    )

    Write-OrionLog `
        -Level "SUCCESS" `
        -Message "Retrieved $($Users.Count) user account(s)."
}
catch {
    Write-OrionLog `
        -Level "ERROR" `
        -Message "Unable to retrieve users: $($_.Exception.Message)"

    throw
}

# -------------------------------------------------------------------
# Build the access-review report
# -------------------------------------------------------------------

foreach ($User in $Users) {
    Write-OrionLog "Reviewing access for '$($User.SamAccountName)'."

    $Manager = Get-ManagerDetails -ManagerDN $User.Manager
    $GroupDNs = @($User.MemberOf)

    if ($GroupDNs.Count -eq 0) {
        Write-OrionLog `
            -Level "WARNING" `
            -Message "'$($User.SamAccountName)' has no direct reviewable group memberships."

        continue
    }

    foreach ($GroupDN in $GroupDNs) {
        try {
            $Group = Get-ADGroup `
                -Identity $GroupDN `
                -Properties Description, GroupCategory, GroupScope `
                -ErrorAction Stop
        }
        catch {
            Write-OrionLog `
                -Level "WARNING" `
                -Message "Could not resolve group '$GroupDN' for '$($User.SamAccountName)'."

            continue
        }

        # Access certification is limited to security-group entitlements.
        if ($Group.GroupCategory -ne "Security") {
            continue
        }

        $Classification = Get-EntitlementClassification -GroupName $Group.Name
        $RiskLevel = Get-EntitlementRisk -Classification $Classification
        $ReviewID = "{0}-{1}-{2}" -f `
            $ExportDate.ToString("yyyyMMdd"),
            $User.SamAccountName,
            $Group.SamAccountName

        $ReviewRows.Add(
            [PSCustomObject]@{
                ReviewCampaign      = $ReviewCampaign
                ReviewID            = $ReviewID
                ExportDate          = $ExportDate.ToString("yyyy-MM-dd HH:mm:ss")
                SamAccountName      = $User.SamAccountName
                DisplayName         = $User.Name
                UserPrincipalName   = $User.UserPrincipalName
                Enabled             = $User.Enabled
                Department          = $User.Department
                Title               = $User.Title
                ManagerName         = $Manager.Name
                ManagerSamAccount   = $Manager.SamAccountName
                ManagerUPN          = $Manager.UserPrincipalName
                GroupName           = $Group.Name
                GroupSamAccountName = $Group.SamAccountName
                GroupCategory       = $Group.GroupCategory
                GroupScope          = $Group.GroupScope
                GroupDescription    = $Group.Description
                AccessType          = $Classification
                RiskLevel           = $RiskLevel
                Decision            = ""
                Reviewer            = ""
                ReviewerComments    = ""
                ReviewDate          = ""
                ProcessingStatus    = "Pending Review"
            }
        )
    }
}

# -------------------------------------------------------------------
# Export the report
# -------------------------------------------------------------------

$RiskOrder = @{
    "Critical" = 1
    "High"     = 2
    "Medium"   = 3
    "Low"      = 4
}

$SortedRows = @(
    $ReviewRows |
        Sort-Object `
            @{ Expression = { $RiskOrder[$_.RiskLevel] } },
            ManagerName,
            SamAccountName,
            GroupName
)

if ($SortedRows.Count -eq 0) {
    Write-OrionLog `
        -Level "WARNING" `
        -Message "No reviewable security-group entitlements were found."

    throw "The access-review export contains no review rows."
}

$SortedRows |
    Export-Csv `
        -Path $ReportPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-OrionLog `
    -Level "SUCCESS" `
    -Message "Exported $($SortedRows.Count) access-review row(s)."

Write-OrionLog `
    -Level "SUCCESS" `
    -Message "Access-review report created at '$ReportPath'."

# -------------------------------------------------------------------
# Display summary
# -------------------------------------------------------------------

$RiskSummary = @(
    $SortedRows |
        Group-Object RiskLevel |
        ForEach-Object {
            [PSCustomObject]@{
                RiskLevel    = $_.Name
                Entitlements = $_.Count
            }
        } |
        Sort-Object {
            $RiskOrder[$_.RiskLevel]
        }
)

Write-Host ""
Write-Host "========================================"
Write-Host " Northstar Access Review Export"
Write-Host "========================================"
Write-Host "Campaign          : $ReviewCampaign"
Write-Host "Users evaluated   : $($Users.Count)"
Write-Host "Review rows       : $($SortedRows.Count)"
Write-Host "Report path       : $ReportPath"
Write-Host "Log path          : $LogPath"
Write-Host "Directory changes : None (read only)"
Write-Host ""

$RiskSummary | Format-Table -AutoSize

Write-Host "Sample review rows:"
$SortedRows |
    Select-Object -First 10 `
        RiskLevel,
        SamAccountName,
        ManagerName,
        GroupName,
        AccessType,
        Decision |
    Format-Table -Wrap -AutoSize
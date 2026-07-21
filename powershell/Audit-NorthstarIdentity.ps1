<#
.SYNOPSIS
    Audits identity and access conditions in the Northstar Active Directory lab.

.DESCRIPTION
    Performs read-only IAM audit checks, including:

    - Disabled users retaining access
    - Users in multiple department groups
    - Users missing their required department group
    - Department and OU mismatches
    - Accounts with passwords set to never expire
    - Stale enabled accounts
    - Missing department or title attributes
    - Privileged group memberships
    - Empty security groups

    Findings are exported to CSV and written to a log file.

.NOTES
    Project: Project Orion
    Organization: Northstar Aerospace Systems
    Domain: ad.northstar.local
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ReportPath = ".\reports\identity-audit.csv",

    [Parameter()]
    [string]$LogPath = ".\logs\identity-audit.log",

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$StaleDays = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory -ErrorAction Stop

# -------------------------------------------------------------------
# Environment configuration
# -------------------------------------------------------------------

$DomainDN = "DC=ad,DC=northstar,DC=local"
$PeopleOU = "OU=People,OU=Northstar,$DomainDN"

$DepartmentGroups = @{
    "Engineering"            = "GG_Engineering"
    "Finance"                = "GG_Finance"
    "Human Resources"        = "GG_HumanResources"
    "Information Technology" = "GG_InformationTechnology"
    "Contractors"            = "GG_Contractors"
    "Executive"              = "GG_Executive"
    "Legal"                  = "GG_Legal"
    "Operations"             = "GG_Operations"
    "Sales"                  = "GG_Sales"
    "Support"                = "GG_Support"
}

$BaselineAccessGroups = @(
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

$ProtectedGroups = @(
    $DepartmentGroups.Values
    $BaselineAccessGroups
    $PrivilegedGroups
) | ForEach-Object { $_ } | Select-Object -Unique

$Findings = [System.Collections.Generic.List[object]]::new()
$AuditDate = Get-Date
$StaleCutoff = $AuditDate.AddDays(-$StaleDays)

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

function Add-AuditFinding {
    param (
        [Parameter(Mandatory)]
        [string]$FindingType,

        [Parameter(Mandatory)]
        [ValidateSet("Low", "Medium", "High", "Critical")]
        [string]$Severity,

        [Parameter()]
        [Microsoft.ActiveDirectory.Management.ADUser]$User,

        [Parameter()]
        [string]$GroupName,

        [Parameter(Mandatory)]
        [string]$Details,

        [Parameter(Mandatory)]
        [string]$RecommendedAction
    )

    $Findings.Add(
        [PSCustomObject]@{
            AuditDate        = $AuditDate.ToString("yyyy-MM-dd HH:mm:ss")
            FindingType      = $FindingType
            Severity         = $Severity
            SamAccountName   = if ($User) { $User.SamAccountName } else { "" }
            DisplayName      = if ($User) { $User.Name } else { "" }
            Enabled          = if ($User) { $User.Enabled } else { "" }
            Department       = if ($User) { $User.Department } else { "" }
            Title            = if ($User) { $User.Title } else { "" }
            LastLogonDate    = if ($User -and $User.LastLogonDate) {
                $User.LastLogonDate.ToString("yyyy-MM-dd HH:mm:ss")
            }
            else {
                ""
            }
            GroupName        = $GroupName
            DistinguishedName = if ($User) { $User.DistinguishedName } else { "" }
            Details          = $Details
            RecommendedAction = $RecommendedAction
        }
    )
}

function Get-UserGroupNames {
    param (
        [Parameter(Mandatory)]
        [Microsoft.ActiveDirectory.Management.ADUser]$User
    )

    try {
        return @(
            Get-ADPrincipalGroupMembership -Identity $User -ErrorAction Stop |
                Select-Object -ExpandProperty Name
        )
    }
    catch {
        Write-OrionLog `
            -Level "WARNING" `
            -Message "Could not retrieve group membership for '$($User.SamAccountName)': $($_.Exception.Message)"

        return @()
    }
}

function Get-ExpectedDepartmentOU {
    param (
        [Parameter(Mandatory)]
        [string]$Department
    )

    return "OU=$Department,$PeopleOU"
}

# -------------------------------------------------------------------
# Prepare output directories
# -------------------------------------------------------------------

$ReportDirectory = Split-Path -Path $ReportPath -Parent
$LogDirectory = Split-Path -Path $LogPath -Parent

if ($ReportDirectory -and -not (Test-Path $ReportDirectory)) {
    New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null
}

if ($LogDirectory -and -not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

Set-Content -Path $LogPath -Value ""

Write-OrionLog "Starting Northstar identity audit."
Write-OrionLog "Stale account threshold: $StaleDays days."
Write-OrionLog "Audit scope: $PeopleOU"

# -------------------------------------------------------------------
# Retrieve users
# -------------------------------------------------------------------

try {
    $Users = @(
        Get-ADUser `
            -Filter * `
            -SearchBase $PeopleOU `
            -Properties Department,
                        Title,
                        Enabled,
                        PasswordNeverExpires,
                        LastLogonDate,
                        WhenCreated,
                        WhenChanged,
                        MemberOf
    )

    Write-OrionLog `
        -Level "SUCCESS" `
        -Message "Retrieved $($Users.Count) user accounts."
}
catch {
    Write-OrionLog `
        -Level "ERROR" `
        -Message "Unable to retrieve users: $($_.Exception.Message)"

    throw
}

# -------------------------------------------------------------------
# Audit each user
# -------------------------------------------------------------------

foreach ($User in $Users) {

    Write-OrionLog "Auditing '$($User.SamAccountName)'."

    $UserGroups = Get-UserGroupNames -User $User

    # Check 1: Disabled account retains access
    if (-not $User.Enabled) {

        $RetainedAccessGroups = @(
            $UserGroups | Where-Object {
                $_ -ne "Domain Users"
            }
        )

        foreach ($GroupName in $RetainedAccessGroups) {
            Add-AuditFinding `
                -FindingType "DisabledAccountWithAccess" `
                -Severity "High" `
                -User $User `
                -GroupName $GroupName `
                -Details "Disabled account remains assigned to '$GroupName'." `
                -RecommendedAction "Review and remove unnecessary access from the disabled account."
        }
    }

    # Check 2: Missing department attribute
    if ([string]::IsNullOrWhiteSpace($User.Department)) {
        Add-AuditFinding `
            -FindingType "MissingDepartmentAttribute" `
            -Severity "Medium" `
            -User $User `
            -Details "The Department attribute is blank." `
            -RecommendedAction "Assign the correct department based on the authoritative HR record."
    }

    # Check 3: Missing title attribute
    if ([string]::IsNullOrWhiteSpace($User.Title)) {
        Add-AuditFinding `
            -FindingType "MissingTitleAttribute" `
            -Severity "Low" `
            -User $User `
            -Details "The Title attribute is blank." `
            -RecommendedAction "Update the user's job title using the authoritative HR record."
    }

    # Check 4: Password never expires
    if ($User.PasswordNeverExpires) {
        Add-AuditFinding `
            -FindingType "PasswordNeverExpires" `
            -Severity "High" `
            -User $User `
            -Details "The account password is configured to never expire." `
            -RecommendedAction "Confirm whether the setting is justified and apply the appropriate password control."
    }

    # Check 5: Stale enabled account
    if (
        $User.Enabled -and
        $User.LastLogonDate -and
        $User.LastLogonDate -lt $StaleCutoff
    ) {
        Add-AuditFinding `
            -FindingType "StaleEnabledAccount" `
            -Severity "High" `
            -User $User `
            -Details "The account has not logged in since $($User.LastLogonDate.ToString('yyyy-MM-dd'))." `
            -RecommendedAction "Confirm continued employment and business need. Disable the account if it is no longer required."
    }

    # Check 6: Enabled account has never logged in
    if ($User.Enabled -and -not $User.LastLogonDate) {
        Add-AuditFinding `
            -FindingType "EnabledAccountNeverLoggedIn" `
            -Severity "Medium" `
            -User $User `
            -Details "The enabled account has no recorded LastLogonDate." `
            -RecommendedAction "Confirm whether the account is a recent hire, unused account, or improperly provisioned account."
    }

    # Department-based checks
    if (-not [string]::IsNullOrWhiteSpace($User.Department)) {

        if ($DepartmentGroups.ContainsKey($User.Department)) {

            $ExpectedDepartmentGroup = $DepartmentGroups[$User.Department]
            $ExpectedOU = Get-ExpectedDepartmentOU -Department $User.Department

            # Check 7: Missing expected department group
            if ($UserGroups -notcontains $ExpectedDepartmentGroup) {
                Add-AuditFinding `
                    -FindingType "MissingDepartmentGroup" `
                    -Severity "Medium" `
                    -User $User `
                    -GroupName $ExpectedDepartmentGroup `
                    -Details "User belongs to '$($User.Department)' but is not a member of '$ExpectedDepartmentGroup'." `
                    -RecommendedAction "Validate the user's department and add the required department group if approved."
            }

            # Check 8: Department and OU mismatch
            if ($User.DistinguishedName -notlike "*$ExpectedOU") {
                Add-AuditFinding `
                    -FindingType "DepartmentOUMismatch" `
                    -Severity "Medium" `
                    -User $User `
                    -Details "Department is '$($User.Department)', but the user is not located in '$ExpectedOU'." `
                    -RecommendedAction "Validate the user's department and move the account into the correct departmental OU."
            }
        }
        else {
            Add-AuditFinding `
                -FindingType "UnrecognizedDepartment" `
                -Severity "Medium" `
                -User $User `
                -Details "Department '$($User.Department)' is not included in the approved Northstar department mapping." `
                -RecommendedAction "Review the department value and update the approved mapping if necessary."
        }
    }

    # Check 9: Multiple department groups
    $AssignedDepartmentGroups = @(
        $UserGroups | Where-Object {
            $_ -in $DepartmentGroups.Values
        }
    )

    if ($AssignedDepartmentGroups.Count -gt 1) {
        Add-AuditFinding `
            -FindingType "MultipleDepartmentGroups" `
            -Severity "High" `
            -User $User `
            -GroupName ($AssignedDepartmentGroups -join "; ") `
            -Details "User is assigned to multiple department groups: $($AssignedDepartmentGroups -join ', ')." `
            -RecommendedAction "Confirm the user's current department and remove obsolete department memberships."
    }

    # Check 10: Privileged group membership
    $AssignedPrivilegedGroups = @(
        $UserGroups | Where-Object {
            $_ -in $PrivilegedGroups
        }
    )

    foreach ($GroupName in $AssignedPrivilegedGroups) {
        Add-AuditFinding `
            -FindingType "PrivilegedGroupMembership" `
            -Severity "Critical" `
            -User $User `
            -GroupName $GroupName `
            -Details "User is a member of privileged group '$GroupName'." `
            -RecommendedAction "Validate formal approval, administrative need, least privilege, and account separation."
    }
}

# -------------------------------------------------------------------
# Audit empty security groups
# -------------------------------------------------------------------

Write-OrionLog "Auditing empty security groups."

$SecurityGroups = @(
    Get-ADGroup `
        -Filter "GroupCategory -eq 'Security'" `
        -Properties Members
)

foreach ($Group in $SecurityGroups) {

    if (
        $Group.Members.Count -eq 0 -and
        $Group.Name -notin $ProtectedGroups
    ) {
        Add-AuditFinding `
            -FindingType "EmptySecurityGroup" `
            -Severity "Low" `
            -GroupName $Group.Name `
            -Details "Security group '$($Group.Name)' has no members." `
            -RecommendedAction "Confirm whether the group is still required and remove it if obsolete."
    }
}

# -------------------------------------------------------------------
# Export report
# -------------------------------------------------------------------

$SeverityOrder = @{
    "Critical" = 1
    "High"     = 2
    "Medium"   = 3
    "Low"      = 4
}

$SortedFindings = @(
    $Findings |
        Sort-Object `
            @{ Expression = { $SeverityOrder[$_.Severity] } },
            FindingType,
            SamAccountName
)

if ($SortedFindings.Count -gt 0) {

    $SortedFindings |
        Export-Csv `
            -Path $ReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-OrionLog `
        -Level "SUCCESS" `
        -Message "Audit completed with $($SortedFindings.Count) finding(s)."

    Write-OrionLog `
        -Level "SUCCESS" `
        -Message "Report exported to '$ReportPath'."
}
else {
    # Create a CSV with headers even when there are no findings.
    [PSCustomObject]@{
        AuditDate         = ""
        FindingType       = ""
        Severity          = ""
        SamAccountName    = ""
        DisplayName       = ""
        Enabled           = ""
        Department        = ""
        Title             = ""
        LastLogonDate     = ""
        GroupName         = ""
        DistinguishedName = ""
        Details           = ""
        RecommendedAction = ""
    } |
        Export-Csv `
            -Path $ReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-OrionLog `
        -Level "SUCCESS" `
        -Message "Audit completed with no findings."
}

# -------------------------------------------------------------------
# Display summary
# -------------------------------------------------------------------

$Summary = $SortedFindings |
    Group-Object Severity |
    ForEach-Object {
        [PSCustomObject]@{
            Severity = $_.Name
            Findings = $_.Count
        }
    } |
    Sort-Object {
        $SeverityOrder[$_.Severity]
    }

Write-Host ""
Write-Host "========================================"
Write-Host " Northstar Identity Audit Summary"
Write-Host "========================================"
Write-Host "Users audited : $($Users.Count)"
Write-Host "Total findings: $($SortedFindings.Count)"
Write-Host "Report path   : $ReportPath"
Write-Host "Log path      : $LogPath"
Write-Host ""

if ($Summary) {
    $Summary | Format-Table -AutoSize
}

if ($SortedFindings.Count -gt 0) {
    Write-Host "Top findings:"
    $SortedFindings |
        Select-Object -First 10 `
            Severity,
            FindingType,
            SamAccountName,
            GroupName,
            Details |
        Format-Table -Wrap -AutoSize
}
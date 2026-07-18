<#
.SYNOPSIS
    Transfers a Northstar employee to a new department in Active Directory.

.DESCRIPTION
    Validates the employee and target department, removes the old department
    group, adds the new department group, updates department and title, and
    moves the account into the correct departmental OU. Baseline access groups
    such as VPN, Microsoft 365, and file-share access are preserved for review.

.NOTES
    Project: Project Orion
    Domain: ad.northstar.local
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SamAccountName,

    [Parameter(Mandatory)]
    [ValidateSet(
        'Contractors',
        'Engineering',
        'Executive',
        'Finance',
        'Human Resources',
        'Information Technology',
        'Manufacturing'
    )]
    [string]$NewDepartment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NewTitle,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason,

    [Parameter()]
    [datetime]$EffectiveDate = (Get-Date),

    [Parameter()]
    [string]$LogPath = "$PSScriptRoot\..\logs\transfers.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop

$DomainDn = 'DC=ad,DC=northstar,DC=local'
$DepartmentGroups = @{
    'Contractors'            = 'GG_Contractors'
    'Engineering'            = 'GG_Engineering'
    'Executive'              = 'GG_Executive'
    'Finance'                = 'GG_Finance'
    'Human Resources'        = 'GG_HR'
    'Information Technology' = 'GG_IT'
    'Manufacturing'          = 'GG_Manufacturing'
}

$ProtectedGroups = @(
    'Administrators',
    'Domain Admins',
    'Enterprise Admins',
    'Schema Admins'
)

function Write-OrionLog {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR', 'PREVIEW')]
        [string]$Level = 'INFO'
    )

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry

    if (-not $WhatIfPreference) {
        $logDirectory = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $entry
    }
}

function Test-OrionPrivilegedUser {
    param (
        [Parameter(Mandatory)]
        [Microsoft.ActiveDirectory.Management.ADUser]$User
    )

    if ($User.SamAccountName -ieq 'Administrator' -or $User.SID.Value -match '-500$') {
        return $true
    }

    foreach ($groupName in $ProtectedGroups) {
        $group = Get-ADGroup -Identity $groupName -ErrorAction SilentlyContinue
        if (-not $group) {
            continue
        }

        $isMember = Get-ADGroupMember -Identity $group -Recursive |
            Where-Object DistinguishedName -EQ $User.DistinguishedName

        if ($isMember) {
            return $true
        }
    }

    return $false
}

try {
    $user = Get-ADUser -Identity $SamAccountName -Properties Department, Title, Enabled, MemberOf, SID

    if (-not $user.Enabled) {
        throw "Safety stop: '$SamAccountName' is disabled. A disabled account cannot be transferred."
    }

    if (Test-OrionPrivilegedUser -User $user) {
        throw "Safety stop: '$SamAccountName' is a built-in or privileged account. Transfer was blocked."
    }

    if ($user.Department -eq $NewDepartment) {
        throw "'$SamAccountName' is already assigned to '$NewDepartment'."
    }

    $targetOu = "OU=$NewDepartment,OU=People,OU=Northstar,$DomainDn"
    if (-not (Get-ADOrganizationalUnit -Identity $targetOu -ErrorAction SilentlyContinue)) {
        throw "Required target OU was not found: $targetOu"
    }

    $newDepartmentGroup = $DepartmentGroups[$NewDepartment]
    if (-not (Get-ADGroup -Identity $newDepartmentGroup -ErrorAction SilentlyContinue)) {
        throw "Required target department group was not found: $newDepartmentGroup"
    }

    $currentDepartmentGroup = $null
    if ($DepartmentGroups.ContainsKey([string]$user.Department)) {
        $currentDepartmentGroup = $DepartmentGroups[[string]$user.Department]
    }

    $effectiveDateText = $EffectiveDate.ToString('yyyy-MM-dd')
    Write-OrionLog "Transfer plan for '$SamAccountName': '$($user.Department)' to '$NewDepartment', effective $effectiveDateText. Reason: $Reason" 'INFO'

    if ($currentDepartmentGroup -and $currentDepartmentGroup -ne $newDepartmentGroup) {
        $isCurrentMember = $user.MemberOf -contains (Get-ADGroup -Identity $currentDepartmentGroup).DistinguishedName
        if ($isCurrentMember -and $PSCmdlet.ShouldProcess("$SamAccountName -> $currentDepartmentGroup", 'Remove old department membership')) {
            Remove-ADGroupMember -Identity $currentDepartmentGroup -Members $user -Confirm:$false
            Write-OrionLog "Removed '$SamAccountName' from '$currentDepartmentGroup'." 'SUCCESS'
        }
    }

    $isNewMember = $user.MemberOf -contains (Get-ADGroup -Identity $newDepartmentGroup).DistinguishedName
    if (-not $isNewMember -and $PSCmdlet.ShouldProcess("$SamAccountName -> $newDepartmentGroup", 'Add new department membership')) {
        Add-ADGroupMember -Identity $newDepartmentGroup -Members $user
        Write-OrionLog "Added '$SamAccountName' to '$newDepartmentGroup'." 'SUCCESS'
    }

    if ($PSCmdlet.ShouldProcess($SamAccountName, "Update department to '$NewDepartment' and title to '$NewTitle'")) {
        Set-ADUser -Identity $user -Department $NewDepartment -Title $NewTitle
        Write-OrionLog "Updated department and title for '$SamAccountName'." 'SUCCESS'
    }

    if ($PSCmdlet.ShouldProcess($SamAccountName, "Move account to $targetOu")) {
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $targetOu
        Write-OrionLog "Moved '$SamAccountName' to the '$NewDepartment' OU." 'SUCCESS'
    }

    if ($WhatIfPreference) {
        Write-OrionLog "Preview completed for '$SamAccountName'; no changes were made." 'PREVIEW'
    }
    else {
        Write-OrionLog "Transfer completed for '$SamAccountName'. Baseline access groups were preserved for review." 'SUCCESS'
    }
}
catch {
    Write-OrionLog "Transfer failed for '$SamAccountName': $($_.Exception.Message)" 'ERROR'
    exit 1
}

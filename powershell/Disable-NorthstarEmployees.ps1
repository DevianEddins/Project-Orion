<#
.SYNOPSIS
    Safely offboards Northstar Active Directory users.

.DESCRIPTION
    Disables an account, removes all non-primary group memberships, updates the
    account description, and moves it to the Northstar Disabled Accounts OU.
    Supports a single SamAccountName or CSV-driven bulk processing.

.NOTES
    Project: Project Orion
    Domain: ad.northstar.local
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Single')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidateNotNullOrEmpty()]
    [string]$SamAccountName,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidateNotNullOrEmpty()]
    [string]$Reason,

    [Parameter(ParameterSetName = 'Single')]
    [datetime]$TerminationDate = (Get-Date),

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter()]
    [string]$LogPath = "$PSScriptRoot\..\logs\offboarding.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop

$DisabledOu = 'OU=Disabled Accounts,OU=Northstar,DC=ad,DC=northstar,DC=local'
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

    # A WhatIf run must not modify Active Directory or the local filesystem.
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

function Disable-OrionEmployee {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter(Mandatory)]
        [string]$OffboardingReason,

        [Parameter(Mandatory)]
        [datetime]$OffboardingDate
    )

    try {
        $user = Get-ADUser -Identity $Identity -Properties Description, Enabled, MemberOf, PrimaryGroupID

        if (Test-OrionPrivilegedUser -User $user) {
            throw "Safety stop: '$($user.SamAccountName)' is a built-in or privileged account. Offboarding was blocked."
        }

        if ($user.DistinguishedName -like "*,$DisabledOu") {
            Write-OrionLog "Skipped '$($user.SamAccountName)': account is already in the Disabled Accounts OU." 'WARNING'
            return
        }

        $dateText = $OffboardingDate.ToString('yyyy-MM-dd')
        $newDescription = "Disabled $dateText | Reason: $OffboardingReason"
        if (-not [string]::IsNullOrWhiteSpace($user.Description)) {
            $newDescription += " | Previous: $($user.Description)"
        }

        if ($PSCmdlet.ShouldProcess($user.SamAccountName, 'Disable Active Directory account')) {
            Disable-ADAccount -Identity $user
            Write-OrionLog "Disabled account '$($user.SamAccountName)'." 'SUCCESS'
        }

        # MemberOf excludes the primary group (normally Domain Users), so the
        # default membership is preserved automatically.
        foreach ($groupDn in @($user.MemberOf)) {
            $group = Get-ADGroup -Identity $groupDn
            if ($PSCmdlet.ShouldProcess("$($user.SamAccountName) -> $($group.Name)", 'Remove group membership')) {
                Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false
                Write-OrionLog "Removed '$($user.SamAccountName)' from '$($group.Name)'." 'SUCCESS'
            }
        }

        if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Set offboarding description to '$newDescription'")) {
            Set-ADUser -Identity $user -Description $newDescription
            Write-OrionLog "Updated description for '$($user.SamAccountName)'." 'SUCCESS'
        }

        if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Move account to $DisabledOu")) {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOu
            Write-OrionLog "Moved '$($user.SamAccountName)' to the Disabled Accounts OU." 'SUCCESS'
        }

        if ($WhatIfPreference) {
            Write-OrionLog "Preview completed for '$($user.SamAccountName)'; no changes were made." 'PREVIEW'
        }
        else {
            Write-OrionLog "Offboarding completed for '$($user.SamAccountName)'." 'SUCCESS'
        }
    }
    catch {
        Write-OrionLog "Offboarding failed for '$Identity': $($_.Exception.Message)" 'ERROR'
    }
}

if (-not (Get-ADOrganizationalUnit -Identity $DisabledOu -ErrorAction SilentlyContinue)) {
    throw "Required OU was not found: $DisabledOu"
}

if ($PSCmdlet.ParameterSetName -eq 'Single') {
    Disable-OrionEmployee `
        -Identity $SamAccountName `
        -OffboardingReason $Reason `
        -OffboardingDate $TerminationDate `
        -WhatIf:$WhatIfPreference
}
else {
    if (-not (Test-Path -LiteralPath $CsvPath)) {
        throw "Offboarding CSV was not found: $CsvPath"
    }

    $records = Import-Csv -LiteralPath $CsvPath
    foreach ($record in $records) {
        if ([string]::IsNullOrWhiteSpace($record.SamAccountName) -or
            [string]::IsNullOrWhiteSpace($record.Reason) -or
            [string]::IsNullOrWhiteSpace($record.TerminationDate)) {
            Write-OrionLog 'Skipped an incomplete offboarding record.' 'WARNING'
            continue
        }

        $parsedDate = [datetime]::MinValue
        if (-not [datetime]::TryParse($record.TerminationDate, [ref]$parsedDate)) {
            Write-OrionLog "Skipped '$($record.SamAccountName)': invalid termination date '$($record.TerminationDate)'." 'ERROR'
            continue
        }

        Disable-OrionEmployee `
            -Identity $record.SamAccountName.Trim() `
            -OffboardingReason $record.Reason.Trim() `
            -OffboardingDate $parsedDate `
            -WhatIf:$WhatIfPreference
    }
}

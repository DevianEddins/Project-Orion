<#
.SYNOPSIS
    Provisions Northstar Aerospace Systems employees in Active Directory.

.DESCRIPTION
    Imports employee records from a CSV file, creates Active Directory user
    accounts, assigns department and access-based groups, and logs all actions.

.NOTES
    Project: Project Orion
    Domain: ad.northstar.local
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [string]$CsvPath = "$PSScriptRoot\..\data\employees.csv",

    [Parameter()]
    [string]$LogPath = "$PSScriptRoot\..\logs\provisioning.log",

    [Parameter()]
    [string]$DefaultPassword = "Northstar!2026"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory

$DomainDn = "DC=ad,DC=northstar,DC=local"
$UpnSuffix = "ad.northstar.local"

$DepartmentGroups = @{
    "Contractors"            = "GG_Contractors"
    "Engineering"            = "GG_Engineering"
    "Executive"              = "GG_Executive"
    "Finance"                = "GG_Finance"
    "Human Resources"        = "GG_HR"
    "Information Technology" = "GG_IT"
    "Manufacturing"          = "GG_Manufacturing"
}

$AccessGroups = @{
    "VPN"       = "GG_VPN_Users"
    "M365"      = "GG_M365_Users"
    "FileShare" = "GG_FileShare_Users"
}

function Write-OrionLog {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"

    Write-Host $Entry

    # This writes the log even when the provisioning script uses -WhatIf.
    [System.IO.File]::AppendAllText(
        $LogPath,
        "$Entry$([Environment]::NewLine)"
    )
}

function New-OrionUsername {
    param (
        [Parameter(Mandatory)]
        [string]$FirstName,

        [Parameter(Mandatory)]
        [string]$LastName
    )

    $BaseUsername = (
        $FirstName.Substring(0, 1) + "." + $LastName
    ).ToLower() -replace "[^a-z0-9.]", ""

    $Username = $BaseUsername
    $Counter = 1

    while (
        Get-ADUser `
            -Filter "SamAccountName -eq '$Username'" `
            -ErrorAction SilentlyContinue
    ) {
        $Username = "$BaseUsername$Counter"
        $Counter++
    }

    return $Username
}

function Add-OrionGroupMembership {
    param (
        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$GroupName,

        [Parameter(Mandatory)]
        [string]$GroupPurpose
    )

    $Group = Get-ADGroup `
        -Identity $GroupName `
        -ErrorAction SilentlyContinue

    if (-not $Group) {
        Write-OrionLog `
            "The $GroupPurpose group '$GroupName' does not exist. Skipped assignment for $Username." `
            "WARNING"

        return
    }

    if ($PSCmdlet.ShouldProcess(
        "$Username -> $GroupName",
        "Add Active Directory group membership"
    )) {
        Add-ADGroupMember `
            -Identity $GroupName `
            -Members $Username

        Write-OrionLog `
            "Added $Username to $GroupPurpose group $GroupName." `
            "SUCCESS"
    }
}

try {
    $LogDirectory = Split-Path -Path $LogPath -Parent

    if (-not (Test-Path $LogDirectory)) {
        New-Item `
            -Path $LogDirectory `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    if (-not (Test-Path $CsvPath)) {
        throw "CSV file was not found: $CsvPath"
    }

    $Employees = Import-Csv -Path $CsvPath

    Write-OrionLog "Starting employee provisioning from $CsvPath"

    foreach ($Employee in $Employees) {
        try {
            $FirstName = ([string]$Employee.FirstName).Trim()
            $LastName = ([string]$Employee.LastName).Trim()
            $Username = ([string]$Employee.Username).Trim().ToLower()
            $Department = ([string]$Employee.Department).Trim()
            $JobTitle = ([string]$Employee.Title).Trim()
            $VpnAccess = ([string]$Employee.VPN).Trim()
            $M365Access = ([string]$Employee.M365).Trim()
            $FileShareAccess = ([string]$Employee.FileShare).Trim()

            if (
                [string]::IsNullOrWhiteSpace($FirstName) -or
                [string]::IsNullOrWhiteSpace($LastName) -or
                [string]::IsNullOrWhiteSpace($Department)
            ) {
                Write-OrionLog `
                    "Skipped an incomplete employee record." `
                    "WARNING"

                continue
            }

            if (-not $DepartmentGroups.ContainsKey($Department)) {
                Write-OrionLog `
                    "Invalid department '$Department' for $FirstName $LastName." `
                    "ERROR"

                continue
            }

            if ([string]::IsNullOrWhiteSpace($Username)) {
                $Username = New-OrionUsername `
                    -FirstName $FirstName `
                    -LastName $LastName
            }

            $Username = $Username -replace "[^a-z0-9.-]", ""

            if ([string]::IsNullOrWhiteSpace($Username)) {
                Write-OrionLog `
                    "A valid username could not be created for $FirstName $LastName." `
                    "ERROR"

                continue
            }

            $DisplayName = "$FirstName $LastName"
            $UserPrincipalName = "$Username@$UpnSuffix"
            $EmailAddress = "$Username@northstaraerospace.com"

            $DepartmentOu = "OU=$Department,OU=People,OU=Northstar,$DomainDn"

            $OuExists = Get-ADOrganizationalUnit `
                -Identity $DepartmentOu `
                -ErrorAction SilentlyContinue

            if (-not $OuExists) {
                Write-OrionLog `
                    "The department OU '$DepartmentOu' does not exist for $DisplayName." `
                    "ERROR"

                continue
            }

            $ExistingSamAccount = Get-ADUser `
                -Filter "SamAccountName -eq '$Username'" `
                -ErrorAction SilentlyContinue

            if ($ExistingSamAccount) {
                Write-OrionLog `
                    "Skipped existing username: $Username" `
                    "WARNING"

                continue
            }

            $ExistingUpn = Get-ADUser `
                -Filter "UserPrincipalName -eq '$UserPrincipalName'" `
                -ErrorAction SilentlyContinue

            if ($ExistingUpn) {
                Write-OrionLog `
                    "Skipped existing account: $UserPrincipalName" `
                    "WARNING"

                continue
            }

            $SecurePassword = ConvertTo-SecureString `
                $DefaultPassword `
                -AsPlainText `
                -Force

            if ($PSCmdlet.ShouldProcess(
                $DisplayName,
                "Create Active Directory user $Username"
            )) {
                New-ADUser `
                    -Name $DisplayName `
                    -GivenName $FirstName `
                    -Surname $LastName `
                    -DisplayName $DisplayName `
                    -SamAccountName $Username `
                    -UserPrincipalName $UserPrincipalName `
                    -EmailAddress $EmailAddress `
                    -Department $Department `
                    -Title $JobTitle `
                    -Path $DepartmentOu `
                    -AccountPassword $SecurePassword `
                    -Enabled $true `
                    -ChangePasswordAtLogon $true

                Write-OrionLog `
                    "Created user $DisplayName with username $Username." `
                    "SUCCESS"
            }

            $DepartmentGroup = $DepartmentGroups[$Department]

            Add-OrionGroupMembership `
                -Username $Username `
                -GroupName $DepartmentGroup `
                -GroupPurpose "department"

            if ($VpnAccess -match "^(Yes|True|1)$") {
                Add-OrionGroupMembership `
                    -Username $Username `
                    -GroupName $AccessGroups["VPN"] `
                    -GroupPurpose "VPN access"
            }

            if ($M365Access -match "^(Yes|True|1)$") {
                Add-OrionGroupMembership `
                    -Username $Username `
                    -GroupName $AccessGroups["M365"] `
                    -GroupPurpose "Microsoft 365 access"
            }

            if ($FileShareAccess -match "^(Yes|True|1)$") {
                Add-OrionGroupMembership `
                    -Username $Username `
                    -GroupName $AccessGroups["FileShare"] `
                    -GroupPurpose "file-share access"
            }
        }
        catch {
            Write-OrionLog `
                "Failed to provision $($Employee.FirstName) $($Employee.LastName): $($_.Exception.Message)" `
                "ERROR"
        }
    }

    Write-OrionLog "Employee provisioning completed."
}
catch {
    Write-OrionLog `
        "Provisioning process failed: $($_.Exception.Message)" `
        "ERROR"

    exit 1
}
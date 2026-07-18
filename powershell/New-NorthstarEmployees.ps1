<#
.SYNOPSIS
    Provisions Northstar Aerospace Systems employees in Active Directory.

.DESCRIPTION
    Imports employee records from a CSV file, creates Active Directory user
    accounts, assigns department and role-based groups, and logs all actions.

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
    Add-Content -Path $LogPath -Value $Entry
}

function New-OrionUsername {
    param (
        [Parameter(Mandatory)]
        [string]$FirstName,

        [Parameter(Mandatory)]
        [string]$LastName
    )

    $BaseUsername = (
        $FirstName.Substring(0, 1) + $LastName
    ).ToLower() -replace "[^a-z0-9]", ""

    $Username = $BaseUsername
    $Counter = 1

    while (Get-ADUser -Filter "SamAccountName -eq '$Username'" -ErrorAction SilentlyContinue) {
        $Username = "$BaseUsername$Counter"
        $Counter++
    }

    return $Username
}

try {
    $LogDirectory = Split-Path -Path $LogPath -Parent

    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $CsvPath)) {
        throw "CSV file was not found: $CsvPath"
    }

    $Employees = Import-Csv -Path $CsvPath

    Write-OrionLog "Starting employee provisioning from $CsvPath"

    foreach ($Employee in $Employees) {
        try {
            $FirstName = $Employee.FirstName.Trim()
            $LastName = $Employee.LastName.Trim()
            $Department = $Employee.Department.Trim()
            $JobTitle = $Employee.JobTitle.Trim()
            $RoleGroup = $Employee.RoleGroup.Trim()

            if (
                [string]::IsNullOrWhiteSpace($FirstName) -or
                [string]::IsNullOrWhiteSpace($LastName) -or
                [string]::IsNullOrWhiteSpace($Department)
            ) {
                Write-OrionLog "Skipped an incomplete employee record." "WARNING"
                continue
            }

            if (-not $DepartmentGroups.ContainsKey($Department)) {
                Write-OrionLog "Invalid department '$Department' for $FirstName $LastName." "ERROR"
                continue
            }

            $Username = New-OrionUsername `
                -FirstName $FirstName `
                -LastName $LastName

            $DisplayName = "$FirstName $LastName"
            $UserPrincipalName = "$Username@$UpnSuffix"
            $EmailAddress = "$Username@northstaraerospace.com"

            $DepartmentOu = "OU=$Department,OU=People,OU=Northstar,$DomainDn"

            $ExistingUser = Get-ADUser `
                -Filter "UserPrincipalName -eq '$UserPrincipalName'" `
                -ErrorAction SilentlyContinue

            if ($ExistingUser) {
                Write-OrionLog "Skipped existing account: $UserPrincipalName" "WARNING"
                continue
            }

            $SecurePassword = ConvertTo-SecureString `
                $DefaultPassword `
                -AsPlainText `
                -Force

            if ($PSCmdlet.ShouldProcess($DisplayName, "Create Active Directory user")) {
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

                Write-OrionLog "Created user $DisplayName with username $Username." "SUCCESS"

                $DepartmentGroup = $DepartmentGroups[$Department]

                Add-ADGroupMember `
                    -Identity $DepartmentGroup `
                    -Members $Username

                Write-OrionLog "Added $Username to $DepartmentGroup." "SUCCESS"

                if (-not [string]::IsNullOrWhiteSpace($RoleGroup)) {
                    $GroupExists = Get-ADGroup `
                        -Identity $RoleGroup `
                        -ErrorAction SilentlyContinue

                    if ($GroupExists) {
                        Add-ADGroupMember `
                            -Identity $RoleGroup `
                            -Members $Username

                        Write-OrionLog "Added $Username to role group $RoleGroup." "SUCCESS"
                    }
                    else {
                        Write-OrionLog "Role group '$RoleGroup' does not exist for $Username." "WARNING"
                    }
                }
            }
        }
        catch {
            Write-OrionLog "Failed to provision $($Employee.FirstName) $($Employee.LastName): $($_.Exception.Message)" "ERROR"
        }
    }

    Write-OrionLog "Employee provisioning completed."
}
catch {
    Write-OrionLog "Provisioning process failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

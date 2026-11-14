<#
.SYNOPSIS
    Creates Active Directory user accounts from a CSV of new hires.

.DESCRIPTION
    Reads a CSV (FirstName, LastName, Department, Title) and, for each row:
      1. Builds a username (first initial + last name, e.g. jsmith).
      2. Adds a number if that username is taken (jsmith2, jsmith3, ...).
      3. Creates the user in the OU for their department.
      4. Sets a random temporary password and forces a change at first logon.
      5. Adds the user to the department's security group (if it exists).
    Writes a results CSV so you have a record of what happened.

    Run it with -WhatIf first: it shows what it WOULD do without changing AD.

.PARAMETER CsvPath
    Path to the new-hire CSV.

.PARAMETER DomainDN
    Distinguished name of the domain, e.g. "DC=lab,DC=local".

.PARAMETER ResultsPath
    Where to write the results CSV. Defaults to .\onboarding-results.csv.

.EXAMPLE
    .\New-HireAccounts.ps1 -CsvPath .\new-hires.csv -DomainDN "DC=lab,DC=local" -WhatIf

.EXAMPLE
    .\New-HireAccounts.ps1 -CsvPath .\new-hires.csv -DomainDN "DC=lab,DC=local"

.NOTES
    Requires the ActiveDirectory module (RSAT on Windows 10/11, or run on a
    domain controller) and rights to create users in the target OUs.
    Practice in a lab domain, never in production.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$DomainDN,

    [string]$ResultsPath = ".\onboarding-results.csv"
)

Import-Module ActiveDirectory -ErrorAction Stop

# Department name in the CSV -> OU and security group in AD.
# Edit this table to match your lab.
$DepartmentMap = @{
    'Accounting' = @{ OU = "OU=Accounting,OU=Staff,$DomainDN"; Group = 'GG-Accounting' }
    'Sales'      = @{ OU = "OU=Sales,OU=Staff,$DomainDN";      Group = 'GG-Sales' }
    'IT'         = @{ OU = "OU=IT,OU=Staff,$DomainDN";         Group = 'GG-IT' }
}

# UPN suffix from the domain DN: "DC=lab,DC=local" -> "lab.local"
$UpnSuffix = ($DomainDN -split ',' | ForEach-Object { $_ -replace '^DC=', '' }) -join '.'

function New-TempPassword {
    # 16 random characters with at least one of each type, so it meets the
    # default domain complexity policy.
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbol = '!@#$%^&*?'
    $all    = $upper + $lower + $digits + $symbol

    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Get-UniqueSamAccountName {
    param([string]$FirstName, [string]$LastName)

    # Letters only, lowercase, max 20 chars (the sAMAccountName limit).
    $base = ($FirstName.Substring(0, 1) + $LastName).ToLower() -replace '[^a-z]', ''
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }

    # Also check names picked earlier in this run, so two Carla/Carl Smiths
    # get csmith and csmith2 even in a -WhatIf preview.
    $candidate = $base
    $n = 2
    while ($script:UsedNames.Contains($candidate) -or
           (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue)) {
        $candidate = "$base$n"
        $n++
    }
    [void]$script:UsedNames.Add($candidate)
    $candidate
}

$script:UsedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# --- Validate the CSV before touching AD ---
$hires = @(Import-Csv -Path $CsvPath)
if ($hires.Count -eq 0) {
    throw "CSV '$CsvPath' has no rows."
}
$required = 'FirstName', 'LastName', 'Department', 'Title'
$missing = $required | Where-Object { $_ -notin $hires[0].PSObject.Properties.Name }
if ($missing) {
    throw "CSV is missing column(s): $($missing -join ', ')"
}

$results = foreach ($hire in $hires) {
    $first = $hire.FirstName.Trim()
    $last  = $hire.LastName.Trim()
    $dept  = $hire.Department.Trim()

    $row = [ordered]@{
        Name           = "$first $last"
        Department     = $dept
        SamAccountName = ''
        TempPassword   = ''
        Status         = ''
    }

    if (-not $first -or -not $last) {
        $row.Status = 'Skipped: missing first or last name'
        [pscustomobject]$row
        continue
    }
    if (-not $DepartmentMap.ContainsKey($dept)) {
        $row.Status = "Skipped: unknown department '$dept'"
        [pscustomobject]$row
        continue
    }

    $target   = $DepartmentMap[$dept]
    $sam      = Get-UniqueSamAccountName -FirstName $first -LastName $last
    $password = New-TempPassword
    $row.SamAccountName = $sam

    $userParams = @{
        Name                  = "$first $last"
        GivenName             = $first
        Surname               = $last
        DisplayName           = "$first $last"
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@$UpnSuffix"
        Title                 = $hire.Title
        Department            = $dept
        Path                  = $target.OU
        AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
    }

    if ($PSCmdlet.ShouldProcess("$first $last ($sam) in $($target.OU)", 'Create AD user')) {
        try {
            New-ADUser @userParams -ErrorAction Stop

            if (Get-ADGroup -Filter "Name -eq '$($target.Group)'" -ErrorAction SilentlyContinue) {
                Add-ADGroupMember -Identity $target.Group -Members $sam -ErrorAction Stop
                $row.Status = "Created, added to $($target.Group)"
            }
            else {
                $row.Status = "Created (group $($target.Group) not found)"
            }
            $row.TempPassword = $password
        }
        catch {
            $row.Status = "Failed: $($_.Exception.Message)"
        }
    }
    else {
        $row.Status = 'WhatIf: not created'
    }

    [pscustomobject]$row
}

$results | Format-Table -AutoSize
$results | Export-Csv -Path $ResultsPath -NoTypeInformation
Write-Host "Results written to $ResultsPath"
Write-Warning 'The results file contains temporary passwords. Hand them out securely, then delete the file.'

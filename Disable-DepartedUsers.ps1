<#
.SYNOPSIS
    Offboards departed users in Active Directory from a CSV.

.DESCRIPTION
    Reads a CSV (SamAccountName, Reason) and, for each user:
      1. Refuses privileged accounts (AdminCount = 1, e.g. Domain Admins).
      2. Records their group memberships (so they can be restored if needed).
      3. Removes them from every group except their primary group (Domain Users).
      4. Disables the account and resets the password to a random value
         nobody knows, so any saved sessions or cached passwords stop working.
      5. Stamps the description with the date, who ran it, and the reason.
      6. Moves the account to the Disabled OU.
    Writes a results CSV listing every group removed.

    The account is disabled, not deleted. Most companies keep disabled
    accounts for a while (30-90 days) before deleting them.

    Run it with -WhatIf first: it shows what it WOULD do without changing AD.

.PARAMETER CsvPath
    Path to the departures CSV.

.PARAMETER DomainDN
    Distinguished name of the domain, e.g. "DC=lab,DC=local".

.PARAMETER DisabledOU
    Where disabled accounts go. Defaults to "OU=Disabled,<DomainDN>".

.PARAMETER ResultsPath
    Where to write the results CSV. Defaults to .\offboarding-results.csv.

.EXAMPLE
    .\Disable-DepartedUsers.ps1 -CsvPath .\departures.csv -DomainDN "DC=lab,DC=local" -WhatIf

.EXAMPLE
    .\Disable-DepartedUsers.ps1 -CsvPath .\departures.csv -DomainDN "DC=lab,DC=local"

.NOTES
    Requires the ActiveDirectory module and rights to modify users, groups
    and the Disabled OU. Practice in a lab domain, never in production.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$DomainDN,

    [string]$DisabledOU,

    [string]$ResultsPath = ".\offboarding-results.csv"
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not $DisabledOU) { $DisabledOU = "OU=Disabled,$DomainDN" }

# Fail early if the Disabled OU doesn't exist, rather than half-offboarding users.
try {
    Get-ADOrganizationalUnit -Identity $DisabledOU -ErrorAction Stop | Out-Null
}
catch {
    throw "Disabled OU '$DisabledOU' not found. Create it first (see README)."
}

function New-RandomPassword {
    # Same idea as the onboarding script: long, random, meets complexity rules.
    # Nobody is told this password; it only exists to lock the account out.
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
    $chars += 1..20 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

# --- Validate the CSV before touching AD ---
$departures = @(Import-Csv -Path $CsvPath)
if ($departures.Count -eq 0) {
    throw "CSV '$CsvPath' has no rows."
}
$required = 'SamAccountName', 'Reason'
$missing = $required | Where-Object { $_ -notin $departures[0].PSObject.Properties.Name }
if ($missing) {
    throw "CSV is missing column(s): $($missing -join ', ')"
}

$runBy = "$env:USERDOMAIN\$env:USERNAME"
$today = Get-Date -Format 'yyyy-MM-dd'

$results = foreach ($row in $departures) {
    $sam    = $row.SamAccountName.Trim()
    $reason = $row.Reason.Trim()

    $out = [ordered]@{
        SamAccountName = $sam
        Name           = ''
        GroupsRemoved  = ''
        OldLocation    = ''
        Status         = ''
    }

    if (-not $sam) {
        $out.Status = 'Skipped: empty SamAccountName'
        [pscustomobject]$out
        continue
    }

    $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" `
        -Properties MemberOf, AdminCount, Enabled, DistinguishedName, ObjectGUID `
        -ErrorAction SilentlyContinue

    if (-not $user) {
        $out.Status = 'Skipped: user not found'
        [pscustomobject]$out
        continue
    }

    $out.Name        = $user.Name
    $out.OldLocation = $user.DistinguishedName

    # Safety check: AdminCount = 1 means AD protects this account as privileged
    # (Domain Admins, Account Operators, ...). Those need a human, not a script.
    if ($user.AdminCount -eq 1) {
        $out.Status = 'Skipped: privileged account (AdminCount=1), offboard manually'
        [pscustomobject]$out
        continue
    }

    # Group names, for the log. MemberOf holds DNs and leaves out the primary
    # group (Domain Users), which can't be removed anyway.
    $groupNames = @($user.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_).Name })
    $out.GroupsRemoved = $groupNames -join '; '

    if (-not $PSCmdlet.ShouldProcess("$($user.Name) ($sam)",
            "Disable, reset password, remove from $($groupNames.Count) group(s), move to $DisabledOU")) {
        $out.Status = 'WhatIf: not changed'
        [pscustomobject]$out
        continue
    }

    # Use the GUID as identity: it stays the same after the account is moved.
    $id = $user.ObjectGUID
    try {
        if ($user.MemberOf) {
            Remove-ADPrincipalGroupMembership -Identity $id -MemberOf $user.MemberOf -Confirm:$false -ErrorAction Stop
        }

        Disable-ADAccount -Identity $id -ErrorAction Stop

        $newPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        Set-ADAccountPassword -Identity $id -Reset -NewPassword $newPassword -ErrorAction Stop

        Set-ADUser -Identity $id -Description "Disabled $today by $runBy. Reason: $reason" -ErrorAction Stop

        # Move last: if anything above failed, the account stays where people expect it.
        if ($user.DistinguishedName -notlike "*,$DisabledOU") {
            Move-ADObject -Identity $id -TargetPath $DisabledOU -ErrorAction Stop
        }

        $out.Status = if ($user.Enabled) { 'Offboarded' } else { 'Offboarded (was already disabled)' }
    }
    catch {
        $out.Status = "Failed partway: $($_.Exception.Message). Check the account by hand."
    }

    [pscustomobject]$out
}

$results | Format-Table -AutoSize
$results | Export-Csv -Path $ResultsPath -NoTypeInformation
Write-Host "Results written to $ResultsPath (keep it: it lists the groups each user was removed from)."

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [ValidateRange(1, 3650)]
    [int]$InactiveDays = 90
)

$cutoff = (Get-Date).AddDays(-$InactiveDays)

Get-ADUser -Filter 'Enabled -eq $true' -SearchBase $SearchBase `
    -SearchScope Subtree -Properties LastLogonDate, WhenCreated -ErrorAction Stop |
    ForEach-Object {
        $lastActivity = $_.LastLogonDate
        $reason = 'Last logon before cutoff'
        if ($null -eq $lastActivity) {
            $lastActivity = $_.WhenCreated
            $reason = 'No recorded logon; account created before cutoff'
        }

        if ($null -ne $lastActivity -and $lastActivity -lt $cutoff) {
            [pscustomobject]@{
                SamAccountName = $_.SamAccountName
                DistinguishedName = $_.DistinguishedName
                LastLogonDate = $_.LastLogonDate
                WhenCreated = $_.WhenCreated
                Reason = $reason
            }
        }
    } | Sort-Object SamAccountName

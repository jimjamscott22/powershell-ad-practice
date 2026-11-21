# PowerShell + Active Directory Practice

Scripts for practicing everyday sysadmin / help-desk tasks against a **lab** Active Directory domain.

> ⚠️ Run these only in a lab domain, never in production.

## Scripts

### `New-HireAccounts.ps1` — onboard users from a CSV

Reads a CSV of new hires and, for each row:

1. Builds a username from first initial + last name (`anguyen`), adding a number if it's taken (`csmith`, `csmith2`).
2. Creates the user in their department's OU, with title, department and UPN.
3. Sets a random temporary password and forces a change at first logon.
4. Adds the user to the department's security group (e.g. `GG-Sales`).
5. Skips bad rows with a reason, and writes a results CSV.

```powershell
# Preview — shows what would happen, changes nothing
.\New-HireAccounts.ps1 -CsvPath .\new-hires.csv -DomainDN "DC=lab,DC=local" -WhatIf

# Run for real
.\New-HireAccounts.ps1 -CsvPath .\new-hires.csv -DomainDN "DC=lab,DC=local"
```

The results file contains temporary passwords. Hand them out securely, then delete it.

`new-hires.csv` is sample data that exercises the edge cases: two Smiths (name collision), an apostrophe (O'Brien), and an unknown department (Marketing, skipped on purpose).

### `Disable-DepartedUsers.ps1` — offboard users from a CSV

Reads a CSV of departed users (`SamAccountName`, `Reason`) and, for each one:

1. Refuses privileged accounts (`AdminCount = 1`, e.g. Domain Admins). Those get offboarded by hand.
2. Removes the user from all groups (except Domain Users, their primary group).
3. Disables the account and resets the password to a random value nobody knows.
4. Stamps the description: `Disabled 2026-11-14 by LAB\you. Reason: ...`.
5. Moves the account to the `Disabled` OU.
6. Writes a results CSV listing every group removed, so a mistake can be undone.

Accounts are disabled, not deleted. Deleting is usually a separate step 30–90 days later.

```powershell
.\Disable-DepartedUsers.ps1 -CsvPath .\departures.csv -DomainDN "DC=lab,DC=local" -WhatIf
.\Disable-DepartedUsers.ps1 -CsvPath .\departures.csv -DomainDN "DC=lab,DC=local"
```

`departures.csv` offboards two of the users the onboarding sample creates (`bokafor`, `csmith2`), plus one name that doesn't exist, to show the "not found" path.

## Additional practice labs

### Stale-account report (read-only Active Directory)

Practice querying a specific OU, filtering on dates, and exporting objects to CSV. Run this from the repository folder after completing the lab setup below. Replace the search base if your lab uses a different domain or OU.

```powershell
$staff = 'OU=Staff,DC=lab,DC=local'
$stale = .\Get-StaleADUsers.ps1 -SearchBase $staff -InactiveDays 90
$stale | Format-Table SamAccountName, LastLogonDate, Reason -AutoSize
$stale | Export-Csv .\stale-users.csv -NoTypeInformation
```

The report searches the selected OU and its children for enabled accounts. If there's no recorded logon, it uses the account's creation date so that newly created accounts aren't flagged immediately. `LastLogonDate` is based on a replicated timestamp and is approximate; use the report for review, not as a reason to disable an account automatically.

**Check your work:** Compare the results for 30 and 90 days. In an unchanged directory, every account in the 90-day report should also appear in the 30-day report. A fresh lab may report no matches. Try a department OU as the search base and verify that accounts from sibling OUs aren't included.

### Audit a departures CSV (offline)

Practice `Import-Csv`, object pipelines, and input validation without AD or RSAT. The goal is to catch missing fields and duplicate usernames before the file goes anywhere near the offboarding script.

1. Import `departures.csv` and count the rows.
2. Use `Where-Object` and `[string]::IsNullOrWhiteSpace()` to find rows missing `SamAccountName` or `Reason`.
3. Use `Group-Object -Property SamAccountName` and filter for groups with `Count` greater than 1.
4. Check that the original sample has **3 rows, 0 missing-field rows, and 0 duplicate groups**. Then work on a copy: duplicate one row and add a different row with a blank reason. Verify that each check catches its intended problem.

<details>
<summary>Reference solution</summary>

```powershell
$rows = @(Import-Csv .\departures.csv)
$missing = @($rows | Where-Object {
    [string]::IsNullOrWhiteSpace($_.SamAccountName) -or
    [string]::IsNullOrWhiteSpace($_.Reason)
})
$duplicates = @($rows | Group-Object -Property SamAccountName |
    Where-Object { $_.Count -gt 1 })

[pscustomobject]@{
    TotalRows        = $rows.Count
    MissingFieldRows = $missing.Count
    DuplicateGroups  = $duplicates.Count
}
```

</details>

This checks the file, not the directory: the `nobody` row passes these checks even though it's intentionally absent from AD.

## Lab setup

1. Install Windows Server (free evaluation) in Hyper-V or VirtualBox and promote it to a domain controller (e.g. `lab.local`).
2. Create OUs: `Staff`, with `Accounting`, `Sales` and `IT` inside it, plus a top-level `Disabled` OU.
3. Optionally create groups `GG-Accounting`, `GG-Sales`, `GG-IT`.
4. Run scripts on the DC, or on a domain-joined machine with RSAT (ActiveDirectory module).

## Ideas for next scripts

- [ ] Add Marketing to the department table so Evan stops being skipped.
- [x] **Offboarding:** disable a user, move them to a `Disabled` OU, strip their groups, log it.
- [ ] **Undo offboarding:** read `offboarding-results.csv` and re-enable a user, restore their groups, and move them back.
- [x] **Stale accounts report:** users with `LastLogonDate` older than 90 days, exported to CSV.
- [ ] **Password-reset helper:** reset a user's password and unlock the account in one step.
- [ ] **Group membership audit:** list members of every `GG-*` group to CSV.

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

## Lab setup

1. Install Windows Server (free evaluation) in Hyper-V or VirtualBox and promote it to a domain controller (e.g. `lab.local`).
2. Create OUs: `Staff`, with `Accounting`, `Sales` and `IT` inside it, plus a top-level `Disabled` OU.
3. Optionally create groups `GG-Accounting`, `GG-Sales`, `GG-IT`.
4. Run scripts on the DC, or on a domain-joined machine with RSAT (ActiveDirectory module).

## Ideas for next scripts

- [ ] Add Marketing to the department table so Evan stops being skipped.
- [x] **Offboarding:** disable a user, move them to a `Disabled` OU, strip their groups, log it.
- [ ] **Undo offboarding:** read `offboarding-results.csv` and re-enable a user, restore their groups, and move them back.
- [ ] **Stale accounts report:** users with `LastLogonDate` older than 90 days, exported to CSV.
- [ ] **Password-reset helper:** reset a user's password and unlock the account in one step.
- [ ] **Group membership audit:** list members of every `GG-*` group to CSV.

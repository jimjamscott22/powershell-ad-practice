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

## Lab setup

1. Install Windows Server (free evaluation) in Hyper-V or VirtualBox and promote it to a domain controller (e.g. `lab.local`).
2. Create OUs: `Staff`, with `Accounting`, `Sales` and `IT` inside it.
3. Optionally create groups `GG-Accounting`, `GG-Sales`, `GG-IT`.
4. Run scripts on the DC, or on a domain-joined machine with RSAT (ActiveDirectory module).

## Ideas for next scripts

- [ ] Add Marketing to the department table so Evan stops being skipped.
- [ ] **Offboarding:** disable a user, move them to a `Disabled` OU, strip their groups, log it.
- [ ] **Stale accounts report:** users with `LastLogonDate` older than 90 days, exported to CSV.
- [ ] **Password-reset helper:** reset a user's password and unlock the account in one step.
- [ ] **Group membership audit:** list members of every `GG-*` group to CSV.

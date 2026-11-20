# PowerShell Labs — Challenge UI Design

**Date:** 2026-11-19
**Status:** Approved (brainstorming), pending implementation plan

## Goal

A stylish static website where the user browses PowerShell/Active Directory practice challenges built from this repo, ticks off steps, keeps notes, and saves progress. The site does **not** execute PowerShell; the user runs code in their own terminal or lab domain controller and self-checks.

## Decisions

| Topic | Decision |
|---|---|
| Execution model | Guide + self-check. No PowerShell runs in the browser or on a server. |
| Framework | Astro (static output) with framework-free TypeScript islands. No React/Vue/Svelte. |
| Content | Migrate existing README labs and scripts into challenge Markdown files, and seed new challenges from the README "Ideas" list. |
| Progress | Per-step checkboxes, derived status, per-challenge notes, solution-viewed flag. Stored in `localStorage` with JSON export/import. |
| Aesthetic | Retro PowerShell terminal console. |
| Hosting | GitHub Pages via GitHub Actions. |

## 1. Architecture & repo layout

```
powershell-ad-practice/
├─ scripts/                    # existing .ps1 + .csv files moved here
│  ├─ New-HireAccounts.ps1
│  ├─ Disable-DepartedUsers.ps1
│  ├─ Get-StaleADUsers.ps1
│  ├─ new-hires.csv
│  └─ departures.csv
├─ site/                       # self-contained Astro project (own package.json)
│  ├─ src/content/challenges/  # one .md per challenge
│  ├─ src/content.config.ts    # zod schema for challenge frontmatter
│  ├─ src/pages/index.astro    # dashboard
│  ├─ src/pages/challenges/[slug].astro
│  ├─ src/components/          # static .astro components
│  ├─ src/islands/             # the only client-side JS (vanilla TS)
│  └─ src/lib/progress.ts      # progress store
├─ docs/superpowers/specs/
└─ .github/workflows/pages.yml # build site/ and deploy to GitHub Pages
```

- Scripts and sample CSVs move from the repo root to `scripts/`. README command examples are updated to the new paths.
- Islands are plain TypeScript modules that bind to Astro-rendered HTML through `data-*` attributes.
- Pages are pre-rendered with a neutral "no progress" state. Islands hydrate saved progress on load without layout shift: reserved space, no content insertion above the fold.

## 2. Challenge content model

Each challenge is `site/src/content/challenges/<slug>.md`. The slug is derived from the filename.

### Frontmatter schema (zod, enforced at build)

| Field | Type | Notes |
|---|---|---|
| `title` | string | required |
| `track` | enum: `onboarding`, `offboarding`, `reporting`, `csv-skills`, `helpdesk` | required |
| `order` | integer ≥ 1 | position within track |
| `difficulty` | enum: `easy`, `medium`, `hard` | required |
| `requiresAD` | boolean | `true` → "LAB DC" badge; `false` → "OFFLINE" badge |
| `script` | string, optional | repo-relative path to a related script, e.g. `scripts/Disable-DepartedUsers.ps1` |
| `steps` | array of `{ id: string, text: string }`, min 1 | `id` is kebab-case and unique within the challenge |

Build-time checks beyond the schema:
- Duplicate step `id`s within a challenge fail the build.
- A `script` path that does not exist (resolved from the repo root) fails the build.
- Duplicate `(track, order)` pairs fail the build.

### Body

- Briefing in Markdown, followed by an optional `## Check your work` section.
- Solutions go in a `:::solution` container directive (via `remark-directive` and a small custom remark plugin). It renders as the hidden solution panel (see §4). The body may contain at most one solution block.
- PowerShell code blocks are highlighted by Shiki using a custom theme matching the site tokens.

### Initial challenges (8)

| Track | Slug | Title | requiresAD | Source |
|---|---|---|---|---|
| onboarding | `new-hire-accounts` | New-hire accounts from CSV | true | existing script |
| onboarding | `add-marketing-department` | Add Marketing department | true | Ideas list |
| offboarding | `disable-departed-users` | Disable departed users | true | existing script |
| offboarding | `undo-offboarding` | Undo offboarding | true | Ideas list |
| reporting | `stale-account-report` | Stale-account report | true | existing README lab |
| reporting | `group-membership-audit` | Group membership audit (`GG-*` → CSV) | true | Ideas list |
| csv-skills | `audit-departures-csv` | Audit a departures CSV | false | existing README lab |
| helpdesk | `password-reset-helper` | Password reset + unlock helper | true | Ideas list |

- Challenges whose solution is an existing script use understand / run with `-WhatIf` / run for real / verify style steps. Their solution block points to the script and shows the key excerpt.
- Seeded challenges use build-it-yourself steps with a reference solution written for this project.
- The README lab content (setup, "Check your work", reference solution) moves into the matching challenge files. The README keeps the lab setup section and a link to the site.

## 3. Progress storage & data flow

### Storage format

A single `localStorage` key, `psLabs.progress.v1`:

```ts
interface ProgressFile {
  version: 1;
  updatedAt: string; // ISO 8601
  challenges: Record<string /* slug */, {
    steps: Record<string /* stepId */, true>; // only ticked ids stored
    notes: string;
    solutionViewed: boolean;
    completedAt: string | null; // set when all known steps become ticked; cleared otherwise
  }>;
}
```

### Derived status (never stored)

Status is computed against the build-time step ids for the challenge:
- **New:** 0 known steps ticked
- **In progress:** at least 1 but not all known steps ticked
- **Complete:** all known steps ticked

Ticked ids that no longer exist in the content are kept in storage but ignored for status.

### `progress.ts` API

The only module that touches `localStorage`.

- `load(): ProgressFile`
- `toggleStep(slug, stepId): void`
- `setNotes(slug, text): void`, debounced 400 ms before persisting
- `markSolutionViewed(slug): void`
- `exportJson(): void` triggers a download named `ps-labs-progress-YYYY-MM-DD.json`
- `importJson(file: File, mode: 'replace' | 'merge'): Promise<ImportResult>`
- `reset(): void`
- `subscribe(fn): () => void` notifies on every change, including changes from other tabs via the `storage` event

### Error handling

- **Corrupt stored data:** unparseable JSON or wrong shape/version. The raw value is copied to `psLabs.progress.corrupt-<timestamp>`, the store starts empty, and a dismissible warning banner is shown. Nothing crashes and no data is silently dropped.
- **Import validation:** checks version, shape and types. An invalid file shows "Import failed — nothing changed". A valid file asks the user to choose:
  - *Replace:* the imported file overwrites current progress.
  - *Merge:* the union of ticked steps; for notes, the challenge entry from the file with the newer `updatedAt` wins; `solutionViewed` is OR-ed.
  - Unknown slugs are preserved in both modes.
- **Storage unavailable:** private mode, quota exceeded, or access throws. Progress works in memory for the session and a persistent banner shows "Progress won't be saved in this browser".

## 4. Screens & visual system

### Dashboard (`/`)

- Header prompt line `PS C:\Labs> Get-Challenge` with a blinking cursor.
- Overall progress: block-character bar (`[■■■■■□□□] 62%`), plus counts for steps done/total and challenges complete/total.
- One box-drawn panel per track listing its challenges in `order`. Each row shows name, status glyph and text (`✓ DONE`, `… 2/4`, `○ NEW`), a difficulty badge and a `LAB DC`/`OFFLINE` badge.
- Filter row: All / Not started / In progress / Done, plus an "offline only" toggle. Filters are client-side and not persisted.
- Footer: Export, Import, Reset. Reset opens a dialog that requires typing `Remove-Progress -Confirm` exactly.

### Challenge page (`/challenges/<slug>`)

- Path-style breadcrumb, e.g. `C:\Labs\Offboarding\Undo-Offboarding.ps1`, linking back to the dashboard.
- Two columns: the briefing (Markdown body) on the left, and a sticky right panel containing:
  - Objectives checklist (`[x]`-styled real checkboxes)
  - Derived status
  - Related script path, if any
  - Notes textarea (monospace, autosaves, shows "saved ✓" after persisting)
- Solution panel: initially shows `██████ ENCRYPTED ██████` and a "Decrypt" button. Clicking plays a short text-scramble reveal (skipped under `prefers-reduced-motion`), shows the solution and calls `markSolutionViewed`. Once viewed, the panel stays open on later visits.
- Previous/next navigation within the track.

### Visual tokens

| Token | Value | Use |
|---|---|---|
| `--bg` | `#012456` → `#0a0f1a` gradient | page background |
| `--text` | `#d6e2f0` | body text |
| `--cyan` | `#4fd1e8` | complete state, links |
| `--amber` | `#ffb547` | in-progress state |
| `--dim` | muted gray | new state, secondary text |
| `--red` | error red | errors, destructive actions |

- Fonts: **JetBrains Mono** for headings, UI and code; **IBM Plex Sans** for briefing prose. Both are self-hosted via `@fontsource`.
- Texture: faint scanline overlay and a subtle glow on accent text, both disabled under `prefers-reduced-motion` and `prefers-contrast: more`.
- Dark theme only.

### Responsive & accessibility

- Below 900px: single column, with the checklist panel above the briefing.
- Checkboxes are real `<input type="checkbox">` elements with `<label>`s. Progress bars use `role="progressbar"` with `aria-valuenow`. Box-drawing and block characters are `aria-hidden`.
- Status always pairs colour with a glyph and text, never colour alone.
- Visible focus rings on all interactive elements. Dialogs trap focus and close on Escape.

## 5. Testing & deployment

### Testing

- **Vitest unit tests for `progress.ts`:** toggle, derived status (including stale step ids), notes debounce, export shape, import replace/merge/invalid, corrupt-storage recovery, storage-unavailable fallback, unknown-slug preservation.
- **Build-time content checks:** zod schema plus the checks in §2.
- **Playwright smoke test (Chromium):** dashboard loads → open challenge → tick a step → reload, step still ticked → export → reset → import exported file → progress restored.
- **`npm run check`** in `site/` runs `astro check`, Vitest and Playwright.

### Deployment

- `.github/workflows/pages.yml` runs on push to `main`: install, check, build `site/`, deploy to GitHub Pages.
- `astro.config` sets `site` and `base: '/powershell-ad-practice'`. All internal links are built through `import.meta.env.BASE_URL`, with no hard-coded root-relative paths.
- README gets a "Challenge site" section with the Pages link and local dev instructions (`cd site; npm install; npm run dev`), and updated `scripts/` paths.

## Out of scope

- User accounts, cloud sync or any backend
- Executing PowerShell in the browser or via a local server
- Light theme
- Search
- Achievements and badges beyond completion status

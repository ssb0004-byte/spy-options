# Smart Routine Entry

The Add flow has three steps:

1. **Category card:** Prescription, OTC, Peptide, Hormone/TRT, Vitamin/Mineral, Sports Supplement or Compounded.
2. **Search [Category]:** an autocomplete search.
3. **Dose and schedule:** the existing routine form.

## Search (`VitalCore/SubstanceCatalog.swift`, `SubstanceAutocompleteService`)
- Runs entirely on the device against a bundled catalog, so it works offline and nothing typed leaves the phone.
- **Normalisation:** case, accents and punctuation are ignored, so "BPC 157" matches "bpc157" and "BPC-157".
- **Ranking:** exact name, then name prefix, exact alias (brand or abbreviation), alias prefix, word prefix ("d3" finds "Vitamin D3"), substring, and finally typo match. Typo matching allows one typo from 5 characters and two from 8.
- **Short queries:** 1–2 character queries match only beginnings of names and words.
- **Ties:** verified entries rank before custom ones, then by familiarity, length and alphabetical order.
- **De-duplication:** results are unique by entry, and a custom name spelled exactly like a verified one is hidden.
- **Debounce and cache:** a 150 ms debounce (a newer keystroke cancels the older search), plus an in-memory result cache.
- **Never blocks entry:** search never throws. If custom names can't be loaded, verified results still show, and "Add as Custom Substance" is always offered.

## Catalog (`SubstanceCatalogData.swift`, version `2026.10.1`)
- About 400 hand-curated entries.
- **Sources:**
  - RxNorm / DailyMed / Drugs@FDA for medicines
  - NIH ODS for vitamins and supplements
  - PubMed / FDA 503A lists for peptides and compounded ingredients
- Each entry has a stable id, categories, aliases (brands, abbreviations), typical routes, a unit hint and an optional regulatory note.
- **No AI-generated names.** Changes go through pull requests and bump the version.
- The catalog has no dose information.

## Custom substances
- Fields: name, category, alternative name and notes.
- Stored per user in `Application Support/VitalCoach/custom-substances-<user>.json`, with complete file protection. They are not synced and never added to the catalog.
- They can be edited and are always labelled "User-created". The file is deleted on sign-out with wipe and on account deletion.
- The routine records its origin in `user_substances.catalog_ref`:
  - `catalog:<id>@<version>` for a catalog entry
  - `custom:<uuid>` for a user-created name

  The column is nullable (migration `20261014000002`), so existing routines are unchanged.

## Context-aware defaults
- A route is pre-selected only when the catalog lists exactly one; otherwise the user must choose. Oral tablets never default to injection.
- The label unit is suggested only before anything is typed.
- **No dose is ever pre-filled.** Peptide and compounded entries show "enter exactly what your prescriber or label specifies".

## Tests (`SubstanceAutocompleteTests`, 15, run on Linux Swift 6.1)
- Search behaviour:
  - Peptide "tes" → Tesamorelin
  - Prescription "met" → Metformin, Metoprolol
  - brand ↔ generic matching
  - case, accent and punctuation insensitivity
  - typo tolerance
  - short queries and abbreviations
  - category switch
  - no duplicates
- Custom entries:
  - a custom entry persists across a restart (file store) and never enters the catalog
  - offline custom entry
  - a failing store doesn't block search or entry
- Existing routines decode unchanged.
- Route defaults.
- Catalog integrity.
- Debounce cancellation.

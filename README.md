# SkyPoints member and redemption pipeline

This solution treats the three supplied country files as examples for the assessment brief. It uses Snowflake SQL for bulk ingestion and transformations so file-sized work remains inside the warehouse. The files in `sql/` are starter scripts; set the stage names and warehouse/schema access for the target account before running them.

## Design

1. **Land first, preserve source.** Each CSV row is converted to a `VARIANT` object in `RAW.MEMBER_LANDING`, with source filename, row number, batch ID, and ingestion time. The JSON redemption feed is kept intact in `RAW.REDEMPTION_LANDING`.
2. **Normalize by source contract.** `STG.MEMBER_NORMALIZED` maps the three header layouts to one canonical shape and uses a parser selected by source country. IDs remain strings. Parse failures and invalid required fields are recorded in `STG.MEMBER_DQ_QUARANTINE`; they do not fail the whole batch.
3. **Keep a global current profile.** `CORE.MEMBER_PROFILE_CURRENT` is the authoritative current state. Country tables are materialized from it, so a valid country change removes a member from the prior country table and adds them to the new one in the same transaction.
4. **Flatten and deduplicate redemptions.** `CORE.REDEMPTION_TRANSACTION` contains one row per partner transaction key. An unresolved member reference or malformed transaction is quarantined.

For production volume, use an external cloud stage with a storage integration, large compressed files split into many reasonably sized objects, and warehouse `COPY INTO`/SQL transforms. Avoid row-at-a-time inserts. Run one routing transaction per batch (or serialize batches by member key), monitor Snowflake load history and query history, and retain the raw layer for replay. Country-specific physical tables are shown because the assessment asks for them; a single clustered current table with country views is usually simpler to operate at global scale. If physical tables are required for more countries, deploy DDL and routing statements from an allow-listed country registry; never interpolate a country value from a file into SQL.

## Source mapping and assumptions

| Source | Member ID | Name | DOB | Tier | Enrollment | Flight | Country used when missing |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Assessment `GLOBAL_PIPE` | `Member_Id` | `Member_Name` | `DOB` | `Tier_Code` | `Enrollment_Date` | `Last_Flight_Date` | From row's `Country` |
| `IND.csv` | `ID` | `Name` | `DOB` | `TierCode` | `EnrollmentDate` | `Flight Date` | `IND` |
| `USA.csv` | `ID` | `Name` | - | `TierCode` | `EnrollmentDate` | `FlightDate` | `USA` |
| `AUS.csv` | `Unique ID` | `Member Name` | `Date of Birth` | `Tier Type` | `Date of Enrollment` | `Date of Flight` | `AUS` |

`GLOBAL_PIPE` enrollment and flight dates use `YYYYMMDD`, while DOB uses `MMDDYYYY` (`03051985` becomes 1985-03-05). `IND` dates are parsed as month/day/year. `USA` dates are compact US month/day/year strings, with seven or eight digits (for example, `6152022` becomes `2022-06-15`). `AUS` dates use ISO `YYYY-MM-DD`. No parser guesses between locale formats. A value that fails its source parser is invalid; the raw value remains available for correction and replay.

The assessment's data dictionary includes `Post Code`, but its header and detail examples omit that field. The pipe-feed parser follows the shown 10-field detail layout and leaves postal code null; a later contract version that adds the field must get a separate mapping instead of shifting the DOB and active columns. The dictionary also marks `Member Name` as a key while `Member ID` is marked non-key. The implementation uses an immutable member ID/crosswalk for identity because names can change and collide; the assessment's sample IDs and the supplied country files show that IDs can also collide across country namespaces.

The examples reuse IDs `1`, `2`, and `3` in all three files. The pipeline therefore uses a temporary namespaced key (`SRC:<source-country>:<source-id>`) unless `CORE.MEMBER_ID_XREF` supplies a stable global key. This prevents unrelated sample members from being merged. **Country movement cannot be inferred from these sample IDs alone.** In production, the source must provide a global immutable member ID or an authoritative crosswalk that maps each source ID to that global ID. Redemption joins need the same stable ID (or an unambiguous partner crosswalk).

Additional assumptions:

- `ID`/`Unique ID` are identifiers, not numeric measures; leading zeroes must be preserved.
- The source file country is used only when the row has no country field. Explicit country values are normalized (`AU` to `AUS`, `US` to `USA`, `PHIL` to `PHL`, etc.). Targets for `IND`, `USA`, `AUS`, `PHL`, and `CAN` are provisioned to cover the assessment's sample countries and the supplied files.
- `EnrollmentDate` is mandatory. DOB, flight date, tier, state, postal code, active flag, and account type can be null where the source omits them. A literal `NULL` is treated as missing.
- `A`/`Y`/`1` map to active and `I`/`N`/`0` map to inactive. Unknown non-empty flags are quarantined. Account type accepts `I` or `C`.
- These sample layouts have no per-record version timestamp. The scheduler must set `SOURCE_VERSION_TS` from the source manifest/extract time; the script's current-time default is only for a first-time sample load. Always reuse the original source version time on replay so an old file cannot overwrite a newer member version.
- `STALE_MEMBER` is null when no flight date is known; otherwise it is true only when the last flight was more than 90 days before processing date. `AGE` is whole years as of processing date. If downstream users need today's values for profiles that were not resent in today's feed, expose these as query-time derived fields or run a scheduled refresh; stored values describe the last processed profile version.

## What the supplied rows reveal

- The country files have different names and column orders, so a single positional parser is unsafe.
- The dates use three representations. Source-specific parsing is required.
- `AUS.csv` row 2 has an impossible enrollment date, `2021-13-13`; it is quarantined because enrollment is mandatory.
- `AUS.csv` row 1 has a null DOB. DOB is optional, so that row remains valid and its age is unknown.
- Country-file IDs overlap. Global deduplication on the raw ID would merge unrelated members.
- The `IND` rows have an individual/corporate attribute absent from the assessment's base layout. It is retained as an extension field.
- The sample lacks `Active Member`, agent, state, and postal code in most or all sources. These remain null; the pipeline does not invent values.
- Dates in the 2021–2022 examples are stale when processed today. The flag is deliberately calculated at run time rather than hard-coded to the assessment sample date.

With the stated formats, `IND`'s `12/1/1998` is 1998-12-01, and `USA`'s `6152022` / `8202022` are 2022-06-15 / 2022-08-20. In `AUS`, Mike's null DOB gives unknown age but does not invalidate him; Jonnathan's `2021-13-13` enrollment date makes the row invalid and quarantined; Cristina's dates parse normally. On a run dated 2026-11-20, every known 2022 flight date is stale.

## Data quality rules

The normalization SQL checks required member ID, name, and enrollment date; identifier/name/tier/state/country lengths; valid calendar dates; future DOB/flight dates; flight before enrollment; tier values; account type; active flag; configured target country; and duplicate identifiers within a source file. Errors are retained as an array on the normalized row and copied to quarantine. The validation SQL also reports duplicate keys and target-table routing drift.

Snowflake standard-table primary/unique constraints are not used as the enforcement mechanism. The pipeline deduplicates with `ROW_NUMBER()` and merges by the durable member key; operational monitoring must fail the batch if the validation queries return violations.

## Run order

1. Run `sql/01_ddl.sql` once. Configure the stage integration and folder paths.
2. Upload daily files under `GLOBAL/` (the assessment's pipe-delimited `H`/`D` feed), `IND/`, `USA/`, `AUS/`, and `REDEMPTIONS/` in the stage. Check each file's header/schema fingerprint against its registered layout before loading; the SQL projections assume the exact column order shown. The examples include header rows for CSV and JSON Lines or one JSON object per file for redemptions.
3. Run `sql/02_member_pipeline.sql` once per batch. It creates the batch ID, bulk-loads the three layouts, normalizes them, quarantines invalid rows, and atomically updates the current and country tables.
4. Run `sql/03_redemption_pipeline.sql` for each redemption batch.
5. Run `sql/04_validation_queries.sql` and review batch counts, quarantine reasons, duplicate keys, and country-table consistency before marking the batch complete.

The SQL scripts use a single-batch session variable, `$BATCH_ID`. Preserve the same value for all statements in a run. In a scheduler, pass a generated UUID as a session variable and record the job/run ID in orchestration metadata.

## Demo walkthrough

1. Show the three raw layouts and explain the explicit source mapping.
2. Load a clean row from each source and show the canonical staging row, parsed dates, derived age, and stale flag.
3. Load the AUS row with `2021-13-13` and show the raw value plus its quarantine reason.
4. Show that missing DOB produces a null age without rejecting the member.
5. Add a global-ID crosswalk, stage a later country version for the same global key, rerun routing, and show the prior country row removed and the new one present.
6. Load the sample redemption object and show one flattened row per element of `redemptions`, joined through a global member key.

The assessment PDF also requests incremental commits as submission history. That is workflow guidance inside the attachment; this solution creates local files only and does not modify Git history.

## References

- Snowflake documents `COPY INTO` transformations from staged files and supports CSV field delimiters including `NONE`; this solution instead maps each known CSV layout with a source-specific `COPY` projection into `VARIANT`. [COPY INTO `<table>`](https://docs.snowflake.com/en/sql-reference/sql/copy-into-table)
- Snowflake supports loading JSON into `VARIANT`, which is used for the raw redemption payload. [Loading JSON into a VARIANT column](https://docs.snowflake.com/en/sql-reference/sql/copy-into-table#loading-json-data-into-a-variant-column)

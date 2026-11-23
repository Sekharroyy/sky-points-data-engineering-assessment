# SkyPoints member and redemption pipeline

This repository contains Snowflake SQL for the SkyPoints data engineering assessment: source landing, member normalization and validation, current-profile routing, and JSON redemption flattening.

## Assessment design

- RAW keeps the source payload and file metadata for replay and audit.
- STG.MEMBER_NORMALIZED maps the country-specific files to one member shape. Dates are parsed using the format defined by each source layout; IDs remain strings.
- Invalid member rows stay in staging with an array of data-quality errors and are copied to STG.MEMBER_DQ_QUARANTINE. Valid rows continue through the batch.
- The assessment marks Member Name as the key and Member ID as a non-key attribute. The pipeline uses NAME: plus the trimmed, upper-case name as its fallback MEMBER_KEY. An authoritative crosswalk can provide a canonical key when one is available.
- The newest valid row for a key becomes the current profile. The country-specific tables are refreshed from that current profile so a country change does not leave the member in two country tables.
- 03_redemption_pipeline.sql flattens the redemptions array and resolves partner member IDs through CORE.MEMBER_ID_XREF.

Identity limitation: the sample contains a Mike in both USA and AUS. Because the assessment declares name as the key, those rows share the same fallback key and the latest valid row wins. In real data, names can repeat; use an authoritative global ID or crosswalk before merging same-name people.

## Source layouts and date parsing

| Source | Member ID | Name | DOB | Tier | Enrollment | Flight |
| --- | --- | --- | --- | --- | --- | --- |
| Assessment GLOBAL_PIPE | Member_Id | Member_Name | DOB | Tier_Code | Enrollment_Date | Last_Flight_Date |
| IND.csv | ID | Name | DOB | TierCode | EnrollmentDate | Flight Date |
| USA.csv | ID | Name | Not supplied | TierCode | EnrollmentDate | FlightDate |
| AUS.csv | Unique ID | Member Name | Date of Birth | Tier Type | Date of Enrollment | Date of Flight |

- GLOBAL_PIPE uses YYYYMMDD for enrollment and flight dates and MMDDYYYY for DOB.
- IND uses month/day/year dates.
- USA uses compact US month/day/year strings with seven or eight digits.
- AUS uses ISO YYYY-MM-DD dates.

The parsers do not guess between formats. An invalid required enrollment date makes the row invalid; the raw value remains available for review. DOB and flight date can be null. The IND.csv account type is retained as an extension field. The global pipe mapping follows the sample's ten-field detail row; the assessment dictionary mentions Post Code, but the shown pipe header and detail rows omit it.

## Stage layout

Create SKYPOINTS.RAW.FEED_STAGE by running sql/01_ddl.sql once. For the supplied member sample, upload IND.csv, USA.csv, and AUS.csv to the root of that stage. In the upload dialog, select the stage and leave the path empty. 02_member_pipeline.sql uses FILES to select the matching file for each country-specific mapping.

Snowflake's LIST @SKYPOINTS.RAW.FEED_STAGE output includes the stage name as a prefix. For example, FEED_STAGE/IND.csv in the name column means IND.csv is at the stage root; it is not a subfolder named FEED_STAGE.

The assessment's GLOBAL_PIPE layout is supported under GLOBAL/. It was not part of the three country CSVs used in the Snowflake member run. The redemption script expects JSON files under REDEMPTIONS/.

## Run order

1. Run sql/01_ddl.sql once. Use a role and warehouse with access to the database, schema, and stage.
2. Upload the member CSVs to the root of FEED_STAGE. If a global pipe file is supplied, upload it under GLOBAL/.
3. Run all of sql/02_member_pipeline.sql in one Snowflake session. Record the INGEST_BATCH_ID from the final batch summary.
4. In sql/04_validation_queries.sql, replace every '<batch_id>' with that batch ID, keeping the quotes. Run the queries individually. A check documented as "should return no rows" passes when Snowflake reports no results. The ID-length query is a report and should return rows.
5. Run sql/03_redemption_pipeline.sql only after a redemption JSON feed has been uploaded under REDEMPTIONS/ and partner IDs have been mapped in MEMBER_ID_XREF with SOURCE_SYSTEM = 'PARTNER'.

The country CSVs do not carry per-row source-version timestamps. The script uses one batch timestamp as a sample fallback and then uses ingestion metadata and file/row order as deterministic tie-breakers. In production, pass the source extract/version timestamp from the scheduler and reuse it for retries.

## Validation notes for the supplied member rows

The Snowflake member run returned nine normalized rows: three IND, three USA, and three AUS. Eight were valid. The AUS row with enrollment date 2021-13-13 was quarantined with INVALID_OR_MISSING_ENROLLMENT_DATE; AUS's null DOB was allowed. These are expected sample outcomes.

The profile key now follows the assessment's declared Member Name key. If Snowflake tables were built with an earlier version that used country-plus-ID fallback keys, rerun the final pipeline in a clean test database before comparing current-profile or cross-country routing results. The staged row counts and the invalid AUS enrollment result are independent of that key change.

## Redemption input limitation

No separate redemption JSON file was supplied with the local sample files, so the Snowflake redemption table remained empty (REDEMPTION_ROW_COUNT = 0). In that state, UNMATCHED_REDEMPTIONS = 0 is an empty-table result, not an end-to-end redemption validation. The SQL expects one JSON object per member with member_id, feed_date, and a redemptions array containing txn_id, txn_date, partner, miles_redeemed, and status.

## Production considerations

- Use an external cloud stage with a storage integration for production feeds, with files split into appropriately sized objects.
- Retain raw payloads and load metadata for replay and audit; do not use row-at-a-time inserts for large feeds.
- Populate crosswalks from an authoritative identity source. Do not infer that different source IDs belong to one person, or that same-name people are identical, in production.
- Run one routing transaction per logical batch, serialize conflicting member-key updates, and monitor load history, query history, validation results, and quarantine counts.
- The country tables are included because the assessment requests them. A unified current table with country views is often simpler to operate at scale.

## Files

- sql/01_ddl.sql — databases, schemas, file formats, stage, raw/staging/core tables, crosswalk, and country targets.
- sql/02_member_pipeline.sql — country-specific COPY projections, normalization, data-quality checks, quarantine, latest-version merge, and country routing.
- sql/03_redemption_pipeline.sql — JSON landing, array flattening, validation, partner-key resolution, and transaction merge.
- sql/04_validation_queries.sql — batch metrics, quarantine review, duplicate and routing checks, and redemption count/reconciliation.

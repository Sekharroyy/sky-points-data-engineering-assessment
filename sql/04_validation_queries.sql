-- Replace every '<batch_id>' below with the ID returned by 02_member_pipeline.sql.
-- Keep the single quotes around the value. Run each SELECT separately in Snowsight.

-- Row counts and validity rates by source.
SELECT SOURCE_COUNTRY_CODE, IS_VALID, COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.STG.MEMBER_NORMALIZED
WHERE INGEST_BATCH_ID = '<batch_id>'
GROUP BY SOURCE_COUNTRY_CODE, IS_VALID
ORDER BY SOURCE_COUNTRY_CODE, IS_VALID;

-- Review quarantine reasons without losing the raw source row.
SELECT SOURCE_COUNTRY_CODE, SOURCE_FILE, DQ_ERRORS, COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.STG.MEMBER_DQ_QUARANTINE
WHERE INGEST_BATCH_ID = '<batch_id>'
GROUP BY SOURCE_COUNTRY_CODE, SOURCE_FILE, DQ_ERRORS
ORDER BY SOURCE_COUNTRY_CODE, SOURCE_FILE;

-- Duplicate member keys in the current state (should return no rows).
SELECT MEMBER_KEY, COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.CORE.MEMBER_PROFILE_CURRENT
GROUP BY MEMBER_KEY
HAVING COUNT(*) > 1;

-- Any member should be present in exactly one country table and that table should
-- match the country's current value (should return no rows).
WITH locations AS (
  SELECT MEMBER_KEY, 'IND' AS COUNTRY_CODE FROM SKYPOINTS.CORE.MEMBERS_IND
  UNION ALL
  SELECT MEMBER_KEY, 'USA' FROM SKYPOINTS.CORE.MEMBERS_USA
  UNION ALL
  SELECT MEMBER_KEY, 'AUS' FROM SKYPOINTS.CORE.MEMBERS_AUS
  UNION ALL
  SELECT MEMBER_KEY, 'PHL' FROM SKYPOINTS.CORE.MEMBERS_PHL
  UNION ALL
  SELECT MEMBER_KEY, 'CAN' FROM SKYPOINTS.CORE.MEMBERS_CAN
)
SELECT c.MEMBER_KEY, c.COUNTRY_CODE AS PROFILE_COUNTRY,
       COUNT(l.MEMBER_KEY) AS COUNTRY_TABLE_ROWS,
       COUNT_IF(l.COUNTRY_CODE <> c.COUNTRY_CODE) AS WRONG_COUNTRY_ROWS
FROM SKYPOINTS.CORE.MEMBER_PROFILE_CURRENT c
LEFT JOIN locations l ON l.MEMBER_KEY = c.MEMBER_KEY
GROUP BY c.MEMBER_KEY, c.COUNTRY_CODE
HAVING COUNTRY_TABLE_ROWS <> 1 OR WRONG_COUNTRY_ROWS > 0;

-- Duplicate source IDs are meaningful only within their source file/namespace.
-- Member Name is the assessed key; Member ID remains a source attribute.
SELECT SOURCE_COUNTRY_CODE, SOURCE_FILE, MEMBER_ID, COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.STG.MEMBER_NORMALIZED
WHERE INGEST_BATCH_ID = '<batch_id>' AND IS_VALID
GROUP BY SOURCE_COUNTRY_CODE, SOURCE_FILE, MEMBER_ID
HAVING COUNT(*) > 1;

-- Duplicate normalized names in one source file are invalid; the pipeline quarantines
-- them because Member Name is the declared key. A same-name record in another country
-- shares the fallback key and is handled by the latest-valid-version rule.
SELECT SOURCE_COUNTRY_CODE, SOURCE_FILE,
       UPPER(TRIM(MEMBER_NAME)) AS NORMALIZED_MEMBER_NAME,
       COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.STG.MEMBER_NORMALIZED
WHERE INGEST_BATCH_ID = '<batch_id>' AND MEMBER_NAME IS NOT NULL
GROUP BY SOURCE_COUNTRY_CODE, SOURCE_FILE, UPPER(TRIM(MEMBER_NAME))
HAVING COUNT(*) > 1;

-- A normalized name should resolve to one current key. A result needs identity review,
-- usually because a crosswalk split a name or the source identity assumption is wrong.
SELECT UPPER(TRIM(MEMBER_NAME)) AS NORMALIZED_MEMBER_NAME,
       COUNT(DISTINCT MEMBER_KEY) AS MEMBER_KEY_COUNT
FROM SKYPOINTS.CORE.MEMBER_PROFILE_CURRENT
GROUP BY UPPER(TRIM(MEMBER_NAME))
HAVING COUNT(DISTINCT MEMBER_KEY) > 1;

-- Profile ID lengths. The assessment sample contains unusually short IDs; the
-- dictionary gives a maximum length but no fixed/minimum length, so review the
-- distribution with the source owner before turning this into a hard rejection.
SELECT SOURCE_LAYOUT, SOURCE_COUNTRY_CODE, LENGTH(MEMBER_ID) AS ID_LENGTH,
       COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.STG.MEMBER_NORMALIZED
WHERE INGEST_BATCH_ID = '<batch_id>' AND IS_VALID
GROUP BY SOURCE_LAYOUT, SOURCE_COUNTRY_CODE, LENGTH(MEMBER_ID)
ORDER BY SOURCE_LAYOUT, SOURCE_COUNTRY_CODE, ID_LENGTH;

-- A source-local ID should map to one active global key at a time.
SELECT SOURCE_SYSTEM, SOURCE_COUNTRY_CODE, SOURCE_MEMBER_ID, COUNT(*) AS ACTIVE_MAPPINGS
FROM SKYPOINTS.CORE.MEMBER_ID_XREF
WHERE (ACTIVE_FROM IS NULL OR ACTIVE_FROM <= CURRENT_DATE())
  AND (ACTIVE_TO IS NULL OR ACTIVE_TO >= CURRENT_DATE())
GROUP BY SOURCE_SYSTEM, SOURCE_COUNTRY_CODE, SOURCE_MEMBER_ID
HAVING COUNT(*) > 1;

-- Check the table first: a zero count means no redemption file has been loaded yet.
-- In that case, the duplicate and unmatched checks below are empty-table results,
-- not proof that redemption processing succeeded.
SELECT COUNT(*) AS REDEMPTION_ROW_COUNT
FROM SKYPOINTS.CORE.REDEMPTION_TRANSACTION;

-- Duplicate redemption business keys (should return no rows when transactions exist).
SELECT PARTNER_CODE, TXN_ID, COUNT(*) AS ROW_COUNT
FROM SKYPOINTS.CORE.REDEMPTION_TRANSACTION
GROUP BY PARTNER_CODE, TXN_ID
HAVING COUNT(*) > 1;

-- Reconciliation: every valid redemption row should resolve to a current member.
-- A zero count above makes a zero unmatched result vacuous. Historical profile tables
-- are needed if a member can later be deleted or merged.
SELECT COUNT(*) AS UNMATCHED_REDEMPTIONS
FROM SKYPOINTS.CORE.REDEMPTION_TRANSACTION r
LEFT JOIN SKYPOINTS.CORE.MEMBER_PROFILE_CURRENT m USING (MEMBER_KEY)
WHERE m.MEMBER_KEY IS NULL;

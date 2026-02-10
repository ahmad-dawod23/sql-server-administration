-----------------------------------------------------------------------
-- INDEX & STATISTICS MAINTENANCE
-- Purpose : Detect fragmented indexes and stale statistics, then
--           rebuild / reorganize / update as needed.
-- Safety  : The detection queries are read-only.
--           The maintenance sections use ALTER INDEX and UPDATE STATISTICS
--           — review thresholds and run in a maintenance window.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. INDEX FRAGMENTATION OVERVIEW (current database)
--    Shows every index with > 5 % fragmentation and > 1 000 pages.
--    Small indexes (< 1 000 pages) rarely benefit from rebuilds.
-----------------------------------------------------------------------
SELECT
    DB_NAME()                                     AS [Database],
    SCHEMA_NAME(o.[schema_id])                    AS [Schema],
    o.[name]                                      AS [Table],
    i.[name]                                      AS [Index],
    i.[type_desc]                                 AS IndexType,
    ips.index_type_desc                           AS IndexTypeDesc,
    ips.avg_fragmentation_in_percent              AS FragPct,
    ips.page_count                                AS Pages,
    ips.avg_page_space_used_in_percent            AS AvgPageDensityPct,
    ips.record_count                              AS [Rows],
    ips.fragment_count                            AS Fragments,
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent > 5  THEN 'REORGANIZE'
        ELSE 'OK'
    END                                           AS Recommendation
FROM sys.dm_db_index_physical_stats(
        DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
    JOIN sys.objects  o ON ips.[object_id] = o.[object_id]
    JOIN sys.indexes  i ON ips.[object_id] = i.[object_id]
                        AND ips.index_id    = i.index_id
WHERE ips.avg_fragmentation_in_percent > 5
  AND ips.page_count > 1000
  AND o.is_ms_shipped = 0
ORDER BY ips.avg_fragmentation_in_percent DESC;

-----------------------------------------------------------------------
-- 2. GENERATE REBUILD / REORGANIZE STATEMENTS
--    Copy-paste or wrap in a cursor to execute.
--    Uses ONLINE = ON where the edition supports it.
-----------------------------------------------------------------------
SELECT
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30
            THEN 'ALTER INDEX ' + QUOTENAME(i.[name])
               + ' ON ' + QUOTENAME(SCHEMA_NAME(o.[schema_id]))
               + '.' + QUOTENAME(o.[name])
               + ' REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON, MAXDOP = 4);'
        WHEN ips.avg_fragmentation_in_percent > 5
            THEN 'ALTER INDEX ' + QUOTENAME(i.[name])
               + ' ON ' + QUOTENAME(SCHEMA_NAME(o.[schema_id]))
               + '.' + QUOTENAME(o.[name])
               + ' REORGANIZE;'
    END AS MaintenanceCommand,
    ips.avg_fragmentation_in_percent AS FragPct,
    ips.page_count                   AS Pages
FROM sys.dm_db_index_physical_stats(
        DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
    JOIN sys.objects  o ON ips.[object_id] = o.[object_id]
    JOIN sys.indexes  i ON ips.[object_id] = i.[object_id]
                        AND ips.index_id    = i.index_id
WHERE ips.avg_fragmentation_in_percent > 5
  AND ips.page_count > 1000
  AND i.[name] IS NOT NULL
  AND o.is_ms_shipped = 0
ORDER BY ips.avg_fragmentation_in_percent DESC;

-----------------------------------------------------------------------
-- 3. MISSING INDEXES (top 25 by improvement measure)
--    These are recommendations only. Always validate before creating.
-----------------------------------------------------------------------
SELECT TOP 25
    CONVERT(DECIMAL(18,2),
        migs.avg_user_impact * (migs.user_seeks + migs.user_scans))
                                                    AS ImprovementMeasure,
    DB_NAME(mid.database_id)                        AS [Database],
    mid.[statement]                                 AS [Table],
    mid.equality_columns                            AS EqualityCols,
    mid.inequality_columns                          AS InequalityCols,
    mid.included_columns                            AS IncludedCols,
    migs.user_seeks                                 AS Seeks,
    migs.user_scans                                 AS Scans,
    migs.avg_user_impact                            AS AvgImpactPct,
    migs.last_user_seek                             AS LastSeek,
    'CREATE NONCLUSTERED INDEX [IX_'
        + REPLACE(REPLACE(REPLACE(
              mid.[statement], '[', ''), ']', ''), '.', '_')
        + '_' + CAST(mid.index_handle AS VARCHAR(10))
        + '] ON ' + mid.[statement]
        + ' (' + ISNULL(mid.equality_columns, '')
        + CASE WHEN mid.equality_columns IS NOT NULL
                AND mid.inequality_columns IS NOT NULL
               THEN ', ' ELSE '' END
        + ISNULL(mid.inequality_columns, '')
        + ') '
        + ISNULL('INCLUDE (' + mid.included_columns + ')', '')
        + ';'                                       AS CreateStatement
FROM sys.dm_db_missing_index_group_stats  migs
    JOIN sys.dm_db_missing_index_groups   mig  ON migs.group_handle = mig.index_group_handle
    JOIN sys.dm_db_missing_index_details  mid  ON mig.index_handle  = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY ImprovementMeasure DESC;

-----------------------------------------------------------------------
-- 4. UNUSED INDEXES (since last service restart)
--    Candidates for removal — but verify with Query Store / workload
--    before dropping.
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(o.[schema_id])                   AS [Schema],
    o.[name]                                     AS [Table],
    i.[name]                                     AS [Index],
    i.[type_desc]                                AS IndexType,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,
    (SELECT SUM(ps.used_page_count) * 8 / 1024.0
     FROM sys.dm_db_partition_stats ps
     WHERE ps.[object_id] = i.[object_id]
       AND ps.index_id    = i.index_id)          AS IndexSizeMB,
    STATS_DATE(i.[object_id], i.index_id)        AS LastStatsUpdate
FROM sys.indexes i
    JOIN sys.objects o ON i.[object_id] = o.[object_id]
    LEFT JOIN sys.dm_db_index_usage_stats ius
        ON i.[object_id] = ius.[object_id]
       AND i.index_id    = ius.index_id
       AND ius.database_id = DB_ID()
WHERE o.is_ms_shipped = 0
  AND i.[type] IN (1, 2)           -- clustered + nonclustered
  AND i.is_primary_key = 0
  AND i.is_unique = 0
  AND ISNULL(ius.user_seeks, 0)   = 0
  AND ISNULL(ius.user_scans, 0)   = 0
  AND ISNULL(ius.user_lookups, 0) = 0
ORDER BY ius.user_updates DESC;

-----------------------------------------------------------------------
-- 5. INDEX USAGE STATS — seek vs scan vs update ratio
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(o.[schema_id])      AS [Schema],
    o.[name]                        AS [Table],
    i.[name]                        AS [Index],
    i.[type_desc]                   AS IndexType,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,
    ius.last_user_seek,
    ius.last_user_scan,
    ius.last_user_lookup,
    ius.last_user_update
FROM sys.indexes i
    JOIN sys.objects o ON i.[object_id] = o.[object_id]
    LEFT JOIN sys.dm_db_index_usage_stats ius
        ON i.[object_id] = ius.[object_id]
       AND i.index_id    = ius.index_id
       AND ius.database_id = DB_ID()
WHERE o.is_ms_shipped = 0
  AND i.[type] > 0
ORDER BY ius.user_seeks + ius.user_scans + ius.user_lookups DESC;

-----------------------------------------------------------------------
-- 6. STALE STATISTICS (not updated in > 7 days or with high mod count)
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(o.[schema_id])               AS [Schema],
    o.[name]                                 AS [Table],
    s.[name]                                 AS [Statistic],
    s.auto_created                           AS AutoCreated,
    s.user_created                           AS UserCreated,
    sp.last_updated                          AS LastUpdated,
    sp.[rows]                                AS [Rows],
    sp.rows_sampled                          AS RowsSampled,
    sp.modification_counter                  AS ModificationCount,
    CAST(100.0 * sp.modification_counter
         / NULLIF(sp.[rows], 0) AS DECIMAL(10,2)) AS ModPct,
    DATEDIFF(DAY, sp.last_updated, GETDATE()) AS DaysSinceUpdate,
    'UPDATE STATISTICS ' + QUOTENAME(SCHEMA_NAME(o.[schema_id]))
        + '.' + QUOTENAME(o.[name])
        + ' ' + QUOTENAME(s.[name])
        + ' WITH FULLSCAN;'                 AS UpdateCommand
FROM sys.stats s
    JOIN sys.objects o ON s.[object_id] = o.[object_id]
    CROSS APPLY sys.dm_db_stats_properties(s.[object_id], s.stats_id) sp
WHERE o.is_ms_shipped = 0
  AND (
        DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7
     OR sp.modification_counter > sp.[rows] * 0.20   -- > 20 % modified
  )
ORDER BY sp.modification_counter DESC;

-----------------------------------------------------------------------
-- 7. UPDATE ALL STATISTICS IN CURRENT DATABASE
--    Uncomment to run — uses default sample size.
-----------------------------------------------------------------------
-- EXEC sp_updatestats;

-----------------------------------------------------------------------
-- 8. UPDATE STATISTICS WITH FULLSCAN FOR ALL USER TABLES
--    Generate statements — useful for maintenance windows.
-----------------------------------------------------------------------
SELECT
    'UPDATE STATISTICS ' + QUOTENAME(SCHEMA_NAME([schema_id]))
    + '.' + QUOTENAME([name]) + ' WITH FULLSCAN;' AS UpdateCommand
FROM sys.tables
WHERE is_ms_shipped = 0
ORDER BY [name];

-----------------------------------------------------------------------
-- 9. INDEX OPERATIONAL STATS — row/page lock waits, latch waits
--    Helps identify contention on specific indexes.
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(o.[schema_id])          AS [Schema],
    o.[name]                            AS [Table],
    i.[name]                            AS [Index],
    ios.row_lock_count,
    ios.row_lock_wait_count,
    ios.row_lock_wait_in_ms,
    ios.page_lock_count,
    ios.page_lock_wait_count,
    ios.page_lock_wait_in_ms,
    ios.page_latch_wait_count,
    ios.page_latch_wait_in_ms,
    ios.page_io_latch_wait_count,
    ios.page_io_latch_wait_in_ms
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) ios
    JOIN sys.objects o ON ios.[object_id] = o.[object_id]
    JOIN sys.indexes i ON ios.[object_id] = i.[object_id]
                       AND ios.index_id   = i.index_id
WHERE o.is_ms_shipped = 0
  AND (ios.row_lock_wait_count > 0 OR ios.page_lock_wait_count > 0)
ORDER BY ios.row_lock_wait_in_ms + ios.page_lock_wait_in_ms DESC;

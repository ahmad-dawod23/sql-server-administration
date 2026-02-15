-----------------------------------------------------------------------
-- INDEX & STATISTICS MAINTENANCE
-- Purpose : Detect fragmented indexes and stale statistics, then
--           rebuild / reorganize / update as needed.
-- Safety  : The detection queries are read-only.
--           The maintenance sections use ALTER INDEX and UPDATE STATISTICS
--           — review thresholds and run in a maintenance window.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: BASIC INDEX AND STATISTICS CHECKS
-----------------------------------------------------------------------

-- 1.1 Shows the status of an indexed table statistics
--     Replace table and index names with actual values
-----------------------------------------------------------------------
DBCC SHOW_STATISTICS('HumanResources.Department', 'AK_Department_Name');
GO

-- 1.2 Index physical status health query
--     Shows all indexes with fragmentation details
-----------------------------------------------------------------------
SELECT 
    dbschemas.name AS [Schema],
    dbtables.name AS [Table],
    dbindexes.name AS [Index],
    indexstats.index_type_desc AS [Index Type],
    indexstats.avg_fragmentation_in_percent AS [Fragmentation (%)],
    indexstats.page_count AS [Page Count],
    indexstats.alloc_unit_type_desc AS [Alloc Unit Type]
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') AS indexstats
    INNER JOIN sys.tables AS dbtables 
        ON indexstats.object_id = dbtables.object_id
    INNER JOIN sys.schemas AS dbschemas 
        ON dbtables.schema_id = dbschemas.schema_id
    INNER JOIN sys.indexes AS dbindexes 
        ON dbtables.object_id = dbindexes.object_id 
        AND indexstats.index_id = dbindexes.index_id
WHERE indexstats.database_id = DB_ID()
ORDER BY indexstats.avg_fragmentation_in_percent DESC;
GO



-----------------------------------------------------------------------
-- SECTION 2: INDEX FRAGMENTATION ANALYSIS
-----------------------------------------------------------------------

-- 2.1 Index fragmentation overview (current database)
--     Shows every index with > 5% fragmentation and > 1,000 pages
--     Small indexes (< 1,000 pages) rarely benefit from rebuilds
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
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
    JOIN sys.objects  o 
        ON ips.[object_id] = o.[object_id]
    JOIN sys.indexes  i 
        ON ips.[object_id] = i.[object_id]
        AND ips.index_id    = i.index_id
WHERE ips.avg_fragmentation_in_percent > 5
    AND ips.page_count > 1000
    AND o.is_ms_shipped = 0
ORDER BY ips.avg_fragmentation_in_percent DESC;
GO

-- 2.2 Generate rebuild/reorganize statements
--     Copy-paste or wrap in a cursor to execute
--     Uses ONLINE = ON where the edition supports it
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
GO

-----------------------------------------------------------------------
-- SECTION 3: MISSING INDEXES ANALYSIS
-----------------------------------------------------------------------

-- 3.1 Missing indexes (top 25 by improvement measure)
--     These are recommendations only. Always validate before creating
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
GO

-- 3.2 Missing index warnings for cached plans in current database
--     Shows cached plans that have missing index recommendations
-----------------------------------------------------------------------
SELECT TOP(25) 
    OBJECT_NAME(objectid) AS [ObjectName], 
    cp.objtype, 
    cp.usecounts, 
    cp.size_in_bytes
    -- , qp.query_plan -- Uncomment if you want the Query Plan
FROM sys.dm_exec_cached_plans AS cp WITH (NOLOCK)
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%MissingIndex%'
    AND qp.dbid = DB_ID()
ORDER BY cp.usecounts DESC 
OPTION (RECOMPILE);
GO

-- 3.3 Stored Procedures with Missing Indexes
--     Find cached stored procedures that have missing index 
--     recommendations in their execution plans.
--     Helps identify procedures that could benefit from additional indexes.
-----------------------------------------------------------------------
SELECT TOP(25) 
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], 
    qs.execution_count AS [Execution Count],
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
    qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
    qs.total_worker_time/qs.execution_count AS [Avg Worker Time],    
    qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
    -- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
    ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
    AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
    AND CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
        LIKE N'%<MissingIndexes>%'
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 4: INDEX USAGE ANALYSIS
-----------------------------------------------------------------------

-- 4.1 Unused indexes (since last service restart)
--     Candidates for removal — but verify with Query Store/workload
--     before dropping
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
GO

-- 4.2 Bad nonclustered indexes (writes > reads)
--     Indexes that have more writes than reads may be hurting performance
-----------------------------------------------------------------------
SELECT 
    SCHEMA_NAME(o.[schema_id]) AS [Schema Name], 
    OBJECT_NAME(s.[object_id]) AS [Table Name],
    i.name AS [Index Name], 
    i.index_id, 
    i.is_disabled, 
    i.is_hypothetical, 
    i.has_filter, 
    i.fill_factor,
    s.user_updates AS [Total Writes], 
    s.user_seeks + s.user_scans + s.user_lookups AS [Total Reads],
    s.user_updates - (s.user_seeks + s.user_scans + s.user_lookups) AS [Difference]
FROM sys.dm_db_index_usage_stats AS s WITH (NOLOCK)
INNER JOIN sys.indexes AS i WITH (NOLOCK)
    ON s.[object_id] = i.[object_id]
    AND i.index_id = s.index_id
INNER JOIN sys.objects AS o WITH (NOLOCK)
    ON i.[object_id] = o.[object_id]
WHERE OBJECTPROPERTY(s.[object_id],'IsUserTable') = 1
    AND s.database_id = DB_ID()
    AND s.user_updates > (s.user_seeks + s.user_scans + s.user_lookups)
    AND i.index_id > 1 
    AND i.[type_desc] = N'NONCLUSTERED'
    AND i.is_primary_key = 0 
    AND i.is_unique_constraint = 0 
    AND i.is_unique = 0
ORDER BY [Difference] DESC, [Total Writes] DESC, [Total Reads] ASC 
OPTION (RECOMPILE);
GO

-- 4.3 Index usage stats — seek vs scan vs update ratio
--     Shows all indexes with their usage patterns
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
GO

-- 4.4 Index read/write stats (all tables in current DB) ordered by writes
--     Comprehensive view of all index usage patterns
-----------------------------------------------------------------------
SELECT 
    SCHEMA_NAME(t.[schema_id]) AS [SchemaName],
    OBJECT_NAME(i.[object_id]) AS [ObjectName], 
    i.[name] AS [IndexName], 
    i.index_id, 
    i.[type_desc] AS [Index Type],
    s.user_updates AS [Writes], 
    s.user_seeks + s.user_scans + s.user_lookups AS [Total Reads], 
    i.fill_factor AS [Fill Factor], 
    i.has_filter, 
    i.filter_definition,
    s.last_system_update, 
    s.last_user_update, 
    i.[allow_page_locks]
FROM sys.indexes AS i WITH (NOLOCK)
LEFT OUTER JOIN sys.dm_db_index_usage_stats AS s WITH (NOLOCK)
    ON i.[object_id] = s.[object_id]
    AND i.index_id = s.index_id
    AND s.database_id = DB_ID()
LEFT OUTER JOIN sys.tables AS t WITH (NOLOCK)
    ON t.[object_id] = i.[object_id]
WHERE OBJECTPROPERTY(i.[object_id],'IsUserTable') = 1
ORDER BY s.user_updates DESC;
GO

-----------------------------------------------------------------------
-- SECTION 5: STATISTICS MAINTENANCE
-----------------------------------------------------------------------

-- 5.1 Stale statistics (not updated in > 7 days or with high mod count)
--     Shows statistics that may need updating
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
GO

-- 5.2 Update all statistics in current database
--     Uncomment to run — uses default sample size
-----------------------------------------------------------------------
-- EXEC sp_updatestats;
-- GO

-- 5.3 Update statistics with FULLSCAN for all user tables
--     Generate statements — useful for maintenance windows
-----------------------------------------------------------------------
SELECT
    'UPDATE STATISTICS ' + QUOTENAME(SCHEMA_NAME([schema_id]))
    + '.' + QUOTENAME([name]) + ' WITH FULLSCAN;' AS UpdateCommand
FROM sys.tables
WHERE is_ms_shipped = 0
ORDER BY [name];
GO

-----------------------------------------------------------------------
-- SECTION 6: INDEX CONTENTION AND OPERATIONAL STATS
-----------------------------------------------------------------------

-- 6.1 Index operational stats — row/page lock waits, latch waits
--     Helps identify contention on specific indexes
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
GO

-----------------------------------------------------------------------
-- SECTION 7: BUFFER CACHE ANALYSIS
-----------------------------------------------------------------------

-- 7.1 Buffer usage by index
--     Shows which tables and indexes are using the most memory in buffer cache
--     Can help identify possible candidates for data compression
-----------------------------------------------------------------------
SELECT 
    fg.name AS [Filegroup Name], 
    SCHEMA_NAME(o.schema_id) AS [Schema Name],
    OBJECT_NAME(p.[object_id]) AS [Object Name], 
    i.name AS [Index Name],
    p.index_id, 
    CAST(COUNT(*)/128.0 AS DECIMAL(10, 2)) AS [Buffer Size (MB)],  
    COUNT(*) AS [BufferCount], 
    p.[rows] AS [Row Count],
    p.data_compression_desc AS [Compression Type]
FROM sys.allocation_units AS a WITH (NOLOCK)
INNER JOIN sys.dm_os_buffer_descriptors AS b WITH (NOLOCK)
    ON a.allocation_unit_id = b.allocation_unit_id
INNER JOIN sys.partitions AS p WITH (NOLOCK)
    ON a.container_id = p.hobt_id
INNER JOIN sys.objects AS o WITH (NOLOCK)
    ON p.object_id = o.object_id
INNER JOIN sys.indexes AS i WITH (NOLOCK)
    ON p.object_id = i.object_id
    AND p.index_id = i.index_id
INNER JOIN sys.database_files AS f WITH (NOLOCK)
    ON b.file_id = f.file_id
INNER JOIN sys.filegroups AS fg WITH (NOLOCK)
    ON f.data_space_id = fg.data_space_id
WHERE b.database_id = CONVERT(int, DB_ID())
    AND p.[object_id] > 100
GROUP BY fg.name, o.schema_id, p.[object_id], i.name, p.index_id, p.[rows], p.data_compression_desc
ORDER BY [Buffer Size (MB)] DESC;
GO

-----------------------------------------------------------------------
-- SECTION 8: TABLE SIZE AND COMPRESSION
-----------------------------------------------------------------------

-- 8.1 Table sizes with row counts and compression status
--     Shows object size, row counts, and compression for clustered index or heap
-----------------------------------------------------------------------
SELECT 
    DB_NAME(DB_ID()) AS [Database Name], 
    SCHEMA_NAME(o.schema_id) AS [Schema Name], 
    OBJECT_NAME(p.object_id) AS [Table Name],
    CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(19,2)) AS [Object Size (MB)],
    SUM(p.rows) AS [Row Count], 
    p.data_compression_desc AS [Compression Type]
FROM sys.objects AS o WITH (NOLOCK)
INNER JOIN sys.partitions AS p WITH (NOLOCK)
    ON p.object_id = o.object_id
INNER JOIN sys.dm_db_partition_stats AS ps WITH (NOLOCK)
    ON p.object_id = ps.object_id
    AND p.partition_id = ps.partition_id
WHERE o.type = 'U'
    AND o.is_ms_shipped = 0
    AND p.index_id IN (0, 1) -- Heap or clustered index
GROUP BY o.schema_id, p.object_id, p.data_compression_desc
ORDER BY [Object Size (MB)] DESC;
GO

-----------------------------------------------------------------------
-- SECTION 9: ADDITIONAL MISSING INDEX ANALYSIS
-----------------------------------------------------------------------

-- 9.1 Missing indexes by index advantage (with query details)
--     Provides detailed missing index recommendations with associated queries
-----------------------------------------------------------------------
SELECT 
    CONVERT(DECIMAL(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) AS [Index Advantage], 
    CONVERT(NVARCHAR(25), migs.last_user_seek, 20) AS [Last User Seek],
    mid.[statement] AS [Database.Schema.Table], 
    COUNT(1) OVER(PARTITION BY mid.[statement]) AS [Missing Indexes For Table], 
    COUNT(1) OVER(PARTITION BY mid.[statement], mid.equality_columns) AS [Similar Missing Indexes], 
    mid.equality_columns, 
    mid.inequality_columns, 
    mid.included_columns, 
    migs.user_seeks, 
    CONVERT(DECIMAL(18,2), migs.avg_total_user_cost) AS [Avg Total User Cost], 
    migs.avg_user_impact,
    REPLACE(REPLACE(LEFT(st.[text], 512), CHAR(10),''), CHAR(13),'') AS [Short Query Text],
    OBJECT_NAME(mid.[object_id]) AS [Table Name], 
    p.rows AS [Table Rows]
FROM sys.dm_db_missing_index_groups AS mig WITH (NOLOCK) 
INNER JOIN sys.dm_db_missing_index_group_stats_query AS migs WITH(NOLOCK) 
    ON mig.index_group_handle = migs.group_handle 
CROSS APPLY sys.dm_exec_sql_text(migs.last_sql_handle) AS st 
INNER JOIN sys.dm_db_missing_index_details AS mid WITH (NOLOCK) 
    ON mig.index_handle = mid.index_handle
INNER JOIN sys.partitions AS p WITH (NOLOCK)
    ON p.[object_id] = mid.[object_id]
WHERE mid.database_id = DB_ID()
    AND p.index_id IN (0, 1) -- Only count rows once
ORDER BY [Index Advantage] DESC;
GO

-----------------------------------------------------------------------
-- END OF INDEX & STATISTICS MAINTENANCE QUERIES
-----------------------------------------------------------------------
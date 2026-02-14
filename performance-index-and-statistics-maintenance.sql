-----------------------------------------------------------------------
-- INDEX & STATISTICS MAINTENANCE
-- Purpose : Detect fragmented indexes and stale statistics, then
--           rebuild / reorganize / update as needed.
-- Safety  : The detection queries are read-only.
--           The maintenance sections use ALTER INDEX and UPDATE STATISTICS
--           — review thresholds and run in a maintenance window.
-----------------------------------------------------------------------



----------------------------------
---- index and satistics checks:
----------------------------------


--- shows the status of an indexed table statistics: 
DBCC SHOW_STATISTICS('HumanResources.Department','AK_Department_Name')

--- index physical status health query:
SELECT 
    dbschemas.name AS 'Schema',
    dbtables.name AS 'Table',
    dbindexes.name AS 'Index',
    indexstats.index_type_desc AS 'Index Type',
    indexstats.avg_fragmentation_in_percent AS 'Fragmentation (%)',
    indexstats.page_count AS 'Page Count',
	indexstats.alloc_unit_type_desc AS 'Alloc Unit Type'
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') AS indexstats
    INNER JOIN sys.tables AS dbtables ON indexstats.object_id = dbtables.object_id
    INNER JOIN sys.schemas AS dbschemas ON dbtables.schema_id = dbschemas.schema_id
    INNER JOIN sys.indexes AS dbindexes ON dbtables.object_id = dbindexes.object_id 
        AND indexstats.index_id = dbindexes.index_id
WHERE 
    indexstats.database_id = DB_ID()
ORDER BY 
    indexstats.avg_fragmentation_in_percent DESC;



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
-- Recovery model, log reuse wait description, log file size, log usage size  (Query 35) (Database Properties)
-- and compatibility level for all databases on instance
SELECT db.[name] AS [Database Name], SUSER_SNAME(db.owner_sid) AS [Database Owner],
db.[compatibility_level] AS [DB Compatibility Level], 
db.recovery_model_desc AS [Recovery Model], 
db.log_reuse_wait_desc AS [Log Reuse Wait Description],
CONVERT(DECIMAL(18,2), ds.cntr_value/1024.0) AS [Total Data File Size on Disk (MB)],
CONVERT(DECIMAL(18,2), ls.cntr_value/1024.0) AS [Total Log File Size on Disk (MB)], 
CONVERT(DECIMAL(18,2), lu.cntr_value/1024.0) AS [Log File Used (MB)],
CAST(CAST(lu.cntr_value AS FLOAT) / CAST(ls.cntr_value AS FLOAT)AS DECIMAL(18,2)) * 100 AS [Log Used %], 
db.page_verify_option_desc AS [Page Verify Option], db.user_access_desc, db.state_desc, db.containment_desc,
db.is_mixed_page_allocation_on,  
db.is_auto_create_stats_on, db.is_auto_update_stats_on, db.is_auto_update_stats_async_on, db.is_parameterization_forced, 
db.snapshot_isolation_state_desc, db.is_read_committed_snapshot_on, db.is_auto_close_on, db.is_auto_shrink_on, 
db.target_recovery_time_in_seconds, db.is_cdc_enabled, db.is_published, db.is_distributor, db.is_sync_with_backup, 
db.group_database_id, db.replica_id, db.is_memory_optimized_enabled, db.is_memory_optimized_elevate_to_snapshot_on, 
db.delayed_durability_desc, db.is_query_store_on, 
db.is_temporal_history_retention_enabled, db.is_accelerated_database_recovery_on,
db.is_data_retention_enabled, db.is_ledger_on, db.is_change_feed_enabled,
db.is_master_key_encrypted_by_server, db.is_encrypted, de.encryption_state, de.percent_complete, de.key_algorithm, de.key_length
FROM sys.databases AS db WITH (NOLOCK)
LEFT OUTER JOIN sys.dm_os_performance_counters AS lu WITH (NOLOCK)
ON db.name = lu.instance_name
LEFT OUTER JOIN sys.dm_os_performance_counters AS ls WITH (NOLOCK)
ON db.name = ls.instance_name
LEFT OUTER JOIN sys.dm_os_performance_counters AS ds WITH (NOLOCK)
ON db.name = ds.instance_name
LEFT OUTER JOIN sys.dm_database_encryption_keys AS de WITH (NOLOCK)


-- Queries 63 through 69 are the "Bad Man List" for stored procedures


-- Top Cached SPs By Execution Count (Query 63) (SP Execution Counts)
SELECT TOP(100) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.execution_count AS [Execution Count],
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_elapsed_time/NULLIF(qs.execution_count, 0) AS [Avg Elapsed Time],
qs.total_worker_time/NULLIF(qs.execution_count, 0) AS [Avg Worker Time],    
qs.total_logical_reads/NULLIF(qs.execution_count, 0) AS [Avg Logical Reads],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)

-- Top Cached SPs By Avg Elapsed Time (Query 64) (SP Avg Elapsed Time)
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.min_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time], 
qs.max_elapsed_time, qs.last_elapsed_time, qs.total_elapsed_time, qs.execution_count, 
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute], 
qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], 
qs.total_worker_time AS [TotalWorkerTime],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY avg_elapsed_time DESC OPTION (RECOMPILE);
------


-- This helps you find high average elapsed time cached stored procedures that
-- may be easy to optimize with standard query tuning techniques






-- Top Cached SPs By Total Worker time. Worker time relates to CPU cost  (Query 65) (SP Worker Time)
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.total_worker_time AS [TotalWorkerTime], 
qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], qs.execution_count, 
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]


-- This helps you find the most expensive cached stored procedures from a CPU perspective
-- You should look at this if you see signs of CPU pressure




-- Top Cached SPs By Total Logical Reads. Logical reads relate to memory pressure  (Query 66) (SP Logical Reads)
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.total_logical_reads AS [TotalLogicalReads], 
qs.total_logical_reads/qs.execution_count AS [AvgLogicalReads],qs.execution_count, 
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute], 
qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY qs.total_logical_reads DESC OPTION (RECOMPILE);

-- Top Cached SPs By Total Physical Reads. Physical reads relate to disk read I/O pressure  (Query 67) (SP Physical Reads)
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.total_physical_reads AS [TotalPhysicalReads], 
qs.total_physical_reads/qs.execution_count AS [AvgPhysicalReads], qs.execution_count, 
qs.total_logical_reads,qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan 
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp

-- Possible Bad NC Indexes (writes > reads)  (Query 71) (Bad NC Indexes)
SELECT SCHEMA_NAME(o.[schema_id]) AS [Schema Name], 
OBJECT_NAME(s.[object_id]) AS [Table Name],
i.name AS [Index Name], i.index_id, 
i.is_disabled, i.is_hypothetical, i.has_filter, i.fill_factor,
s.user_updates AS [Total Writes], s.user_seeks + s.user_scans + s.user_lookups AS [Total Reads],
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
AND i.index_id > 1 AND i.[type_desc] = N'NONCLUSTERED'
AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_unique = 0
ORDER BY [Difference] DESC, [Total Writes] DESC, [Total Reads] ASC OPTION (RECOMPILE);
------

-- Missing Indexes for current database by Index Advantage  (Query 72) (Missing Indexes)
SELECT CONVERT(decimal(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) AS [index_advantage], 
CONVERT(nvarchar(25), migs.last_user_seek, 20) AS [last_user_seek],
mid.[statement] AS [Database.Schema.Table], 
COUNT(1) OVER(PARTITION BY mid.[statement]) AS [missing_indexes_for_table], 
COUNT(1) OVER(PARTITION BY mid.[statement], mid.equality_columns) AS [similar_missing_indexes_for_table], 
mid.equality_columns, mid.inequality_columns, mid.included_columns, migs.user_seeks, 
CONVERT(decimal(18,2), migs.avg_total_user_cost) AS [avg_total_user_,cost], migs.avg_user_impact,
REPLACE(REPLACE(LEFT(st.[text], 512), CHAR(10),''), CHAR(13),'') AS [Short Query Text],
OBJECT_NAME(mid.[object_id]) AS [Table Name], p.rows AS [Table Rows]
FROM sys.dm_db_missing_index_groups AS mig WITH (NOLOCK) 
INNER JOIN sys.dm_db_missing_index_group_stats_query AS migs WITH(NOLOCK) 
ON mig.index_group_handle = migs.group_handle 
CROSS APPLY sys.dm_exec_sql_text(migs.last_sql_handle) AS st 
INNER JOIN sys.dm_db_missing_index_details AS mid WITH (NOLOCK) 
ON mig.index_handle = mid.index_handle
INNER JOIN sys.partitions AS p WITH (NOLOCK)
ON p.[object_id] = mid.[object_id]
WHERE mid.database_id = DB_ID()

-- Look at index advantage, last user seek time, number of user seeks to help determine source and importance
-- SQL Server is overly eager to add included columns, so beware
-- Do not just blindly add indexes that show up from this query!!!
-- H�kan Winther has given me some great suggestions for this query




-- Find missing index warnings for cached plans in the current database  (Query 73) (Missing Index Warnings)
-- Note: This query could take some time on a busy instance
SELECT TOP(25) OBJECT_NAME(objectid) AS [ObjectName], 
               cp.objtype, cp.usecounts, cp.size_in_bytes
--			   , qp.query_plan								-- Uncomment if you want the Query Plan
FROM sys.dm_exec_cached_plans AS cp WITH (NOLOCK)
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%MissingIndex%'
AND qp.dbid = DB_ID()
ORDER BY cp.usecounts DESC OPTION (RECOMPILE);
------


-- Breaks down buffers used by current database by object (table, index) in the buffer cache  (Query 74) (Buffer Usage)
-- Note: This query could take some time on a busy instance
SELECT fg.name AS [Filegroup Name], SCHEMA_NAME(o.schema_id) AS [Schema Name],
OBJECT_NAME(p.[object_id]) AS [Object Name], p.index_id, 
CAST(COUNT(*)/128.0 AS DECIMAL(10, 2)) AS [Buffer size(MB)],  
COUNT(*) AS [BufferCount], p.[rows] AS [Row Count],
p.data_compression_desc AS [Compression Type]
FROM sys.allocation_units AS a WITH (NOLOCK)
INNER JOIN sys.dm_os_buffer_descriptors AS b WITH (NOLOCK)
ON a.allocation_unit_id = b.allocation_unit_id
INNER JOIN sys.partitions AS p WITH (NOLOCK)
ON a.container_id = p.hobt_id
INNER JOIN sys.objects AS o WITH (NOLOCK)
ON p.object_id = o.object_id
INNER JOIN sys.database_files AS f WITH (NOLOCK)
ON b.file_id = f.file_id
INNER JOIN sys.filegroups AS fg WITH (NOLOCK)
ON f.data_space_id = fg.data_space_id
WHERE b.database_id = CONVERT(int, DB_ID())


-- Tells you what tables and indexes are using the most memory in the buffer cache
-- It can help identify possible candidates for data compression




-- Get Schema names, Table names, object size, row counts, and compression status for clustered index or heap  (Query 75) (Table Sizes)
SELECT DB_NAME(DB_ID()) AS [Database Name], SCHEMA_NAME(o.schema_id) AS [Schema Name], 
OBJECT_NAME(p.object_id) AS [Table Name],
CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(19,2)) AS [Object Size (MB)],
SUM(p.rows) AS [Row Count], 
p.data_compression_desc AS [Compression Type]
FROM sys.objects AS o WITH (NOLOCK)
INNER JOIN sys.partitions AS p WITH (NOLOCK)
ON p.object_id = o.object_id
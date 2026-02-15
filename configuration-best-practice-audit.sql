/*******************************************************************************
 * SQL SERVER CONFIGURATION BEST-PRACTICE AUDIT
 * 
 * Purpose: Review all key instance-level and database-level settings against 
 *          documented best practices and flag deviations from recommended values.
 * 
 * Safety:  All queries are read-only.
 * 
 * Note:    "Recommended" values are general-purpose starting points.
 *          Adjust for your specific workload and environment.
 ******************************************************************************/

-----------------------------------------------------------------------
-- SECTION 1: INSTANCE CONFIGURATION BEST-PRACTICE REVIEW
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 KEY sys.configurations SETTINGS WITH RECOMMENDATIONS
-----------------------------------------------------------------------
SELECT
    c.[name]                                     AS Setting,
    c.value                                      AS ConfiguredValue,
    c.value_in_use                               AS RunningValue,
    c.minimum_value                              AS MinAllowed,
    c.maximum_value                              AS MaxAllowed,
    c.is_dynamic                                 AS IsDynamic,
    c.is_advanced                                AS IsAdvanced,

    CASE c.[name]

        -- Memory
        WHEN 'max server memory (MB)' THEN
            CASE WHEN c.value_in_use = 2147483647
                 THEN '*** SET TO A SPECIFIC VALUE (leave 10-20% for OS) ***'
                 ELSE 'OK - set to ' + CAST(c.value_in_use AS VARCHAR) + ' MB'
            END
        WHEN 'min server memory (MB)' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '* Consider setting to ~50% of max server memory *'
                 ELSE 'OK'
            END

        -- Parallelism
        WHEN 'max degree of parallelism' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '*** SET TO # OF CORES (max 8) or workload-appropriate value ***'
                 WHEN c.value_in_use > 8
                 THEN '* Consider <=8 for OLTP workloads *'
                 ELSE 'OK'
            END
        WHEN 'cost threshold for parallelism' THEN
            CASE WHEN c.value_in_use = 5
                 THEN '*** DEFAULT (5) is too low — set to 25-50 for OLTP ***'
                 ELSE 'OK - set to ' + CAST(c.value_in_use AS VARCHAR)
            END

        -- Tempdb
        WHEN 'optimize for ad hoc workloads' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '*** ENABLE (1) — prevents plan cache bloat ***'
                 ELSE 'OK - enabled'
            END

        -- Backup
        WHEN 'backup compression default' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '* Consider enabling (1) — saves I/O and space *'
                 ELSE 'OK - enabled'
            END
        WHEN 'backup checksum default' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '* Consider enabling (1) — catches silent corruption *'
                 ELSE 'OK - enabled'
            END

        -- Remote access
        WHEN 'remote admin connections' THEN
            CASE WHEN c.value_in_use = 0
                 THEN '* Consider enabling (1) for remote DAC *'
                 ELSE 'OK - enabled'
            END
        WHEN 'remote access' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '* Deprecated — consider disabling (0) *'
                 ELSE 'OK - disabled'
            END

        -- Security
        WHEN 'xp_cmdshell' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '*** SECURITY RISK — disable unless required ***'
                 ELSE 'OK - disabled'
            END
        WHEN 'clr enabled' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '* Enabled — verify this is intentional *'
                 ELSE 'OK - disabled'
            END
        WHEN 'Ole Automation Procedures' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '* Enabled — verify this is intentional *'
                 ELSE 'OK - disabled'
            END
        WHEN 'cross db ownership chaining' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '*** SECURITY RISK — disable unless required ***'
                 ELSE 'OK - disabled'
            END
        WHEN 'scan for startup procs' THEN
            CASE WHEN c.value_in_use = 1
                 THEN '* Enabled — verify startup procs are legitimate *'
                 ELSE 'OK'
            END

        -- Query processing
        WHEN 'fill factor (%)' THEN
            CASE WHEN c.value_in_use = 0
                 THEN 'OK - default (100% fill)'
                 ELSE 'Set to ' + CAST(c.value_in_use AS VARCHAR) + '%'
            END

        ELSE 'Review manually'
    END                                          AS Recommendation

FROM sys.configurations c
WHERE c.[name] IN (
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads',
    'backup compression default',
    'backup checksum default',
    'remote admin connections',
    'remote access',
    'xp_cmdshell',
    'clr enabled',
    'Ole Automation Procedures',
    'cross db ownership chaining',
    'scan for startup procs',
    'fill factor (%)',
    'Database Mail XPs',
    'default trace enabled',
    'blocked process threshold (s)',
    'Agent XPs'
)
ORDER BY c.[name];

-----------------------------------------------------------------------
-- 1.2 ALL INSTANCE CONFIGURATIONS (COMPLETE LIST)
-----------------------------------------------------------------------
SELECT 
    name, 
    value, 
    value_in_use, 
    minimum, 
    maximum, 
    [description], 
    is_dynamic, 
    is_advanced
FROM sys.configurations WITH (NOLOCK)
ORDER BY name 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 1.3 TRACE FLAGS CURRENTLY ENABLED
-----------------------------------------------------------------------
DBCC TRACESTATUS(-1);

-----------------------------------------------------------------------
-- SECTION 2: DATABASE-LEVEL CONFIGURATION AUDIT
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 DATABASE SETTINGS AUDIT
--     Flags auto-close, auto-shrink, non-CHECKSUM page verify, etc.
-----------------------------------------------------------------------
SELECT
    [name]                          AS DatabaseName,
    compatibility_level,
    recovery_model_desc             AS RecoveryModel,
    page_verify_option_desc         AS PageVerify,
    is_auto_close_on                AS AutoClose,
    is_auto_shrink_on               AS AutoShrink,
    is_auto_create_stats_on         AS AutoCreateStats,
    is_auto_update_stats_on         AS AutoUpdateStats,
    is_auto_update_stats_async_on   AS AsyncStatsUpdate,
    is_read_committed_snapshot_on   AS RCSI,
    snapshot_isolation_state_desc    AS SnapshotIsolation,
    is_trustworthy_on               AS Trustworthy,
    is_db_chaining_on               AS DBChaining,

    -- Flags
    CASE WHEN is_auto_close_on = 1
         THEN '*** DISABLE AUTO_CLOSE ***' ELSE '' END
    + CASE WHEN is_auto_shrink_on = 1
         THEN ' *** DISABLE AUTO_SHRINK ***' ELSE '' END
    + CASE WHEN page_verify_option_desc <> 'CHECKSUM'
         THEN ' *** SET PAGE_VERIFY CHECKSUM ***' ELSE '' END
    + CASE WHEN is_auto_create_stats_on = 0
         THEN ' * Enable AUTO_CREATE_STATISTICS *' ELSE '' END
    + CASE WHEN is_auto_update_stats_on = 0
         THEN ' * Enable AUTO_UPDATE_STATISTICS *' ELSE '' END
    + CASE WHEN is_trustworthy_on = 1
         THEN ' * TRUSTWORTHY is on — security risk *' ELSE '' END
    + CASE WHEN is_db_chaining_on = 1
         THEN ' * DB_CHAINING is on — review *' ELSE '' END
                                    AS Warnings
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY [name];

-----------------------------------------------------------------------
-- 2.2 DATABASE SCOPED CONFIGURATIONS (SQL Server 2016+)
-----------------------------------------------------------------------
SELECT 
    configuration_id, 
    name, 
    [value] AS [value_for_primary], 
    value_for_secondary, 
    is_value_default
FROM sys.database_scoped_configurations WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- SECTION 3: SYSTEM & SERVICE INFORMATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 SQL SERVER VERSION & PATCH LEVEL
--     Check against latest CU: https://aka.ms/sqlserverbuilds
-----------------------------------------------------------------------
SELECT
    SERVERPROPERTY('MachineName')                AS MachineName,
    SERVERPROPERTY('ServerName')                 AS ServerName,
    SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS ComputerNamePhysicalNetBIOS,
    SERVERPROPERTY('InstanceName')               AS [Instance],
    SERVERPROPERTY('ProductVersion')             AS ProductVersion,
    SERVERPROPERTY('ProductMajorVersion')        AS ProductMajorVersion,
    SERVERPROPERTY('ProductMinorVersion')        AS ProductMinorVersion,
    SERVERPROPERTY('ProductBuild')               AS ProductBuild,
    SERVERPROPERTY('ProductLevel')               AS PatchLevel,
    SERVERPROPERTY('ProductUpdateLevel')         AS CULevel,
    SERVERPROPERTY('ProductBuildType')           AS ProductBuildType,
    SERVERPROPERTY('ProductUpdateReference')     AS ProductUpdateReference,
    SERVERPROPERTY('Edition')                    AS Edition,
    SERVERPROPERTY('EngineEdition')              AS EngineEdition,
    SERVERPROPERTY('ProcessID')                  AS ProcessID,
    SERVERPROPERTY('Collation')                  AS Collation,
    SERVERPROPERTY('IsClustered')                AS IsClustered,
    SERVERPROPERTY('IsHadrEnabled')              AS IsHadrEnabled,
    SERVERPROPERTY('HadrManagerStatus')          AS HadrManagerStatus,
    SERVERPROPERTY('IsFullTextInstalled')        AS IsFullTextInstalled,
    SERVERPROPERTY('IsIntegratedSecurityOnly')   AS IsIntegratedSecurityOnly,
    SERVERPROPERTY('FilestreamConfiguredLevel')  AS FilestreamConfiguredLevel,
    SERVERPROPERTY('InstanceDefaultDataPath')    AS InstanceDefaultDataPath,
    SERVERPROPERTY('InstanceDefaultLogPath')     AS InstanceDefaultLogPath,
    SERVERPROPERTY('InstanceDefaultBackupPath')  AS InstanceDefaultBackupPath,
    SERVERPROPERTY('ErrorLogFileName')           AS ErrorLogFileName,
    SERVERPROPERTY('BuildClrVersion')            AS BuildClrVersion,
    SERVERPROPERTY('IsXTPSupported')             AS IsXTPSupported,
    SERVERPROPERTY('IsPolybaseInstalled')        AS IsPolybaseInstalled,
    SERVERPROPERTY('IsAdvancedAnalyticsInstalled') AS IsRServicesInstalled,
    SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS IsTempdbMetadataMemoryOptimized,
    SERVERPROPERTY('IsServerSuspendedForSnapshotBackup') AS IsServerSuspendedForSnapshotBackup,
    SERVERPROPERTY('SuspendedDatabaseCount')     AS SuspendedDatabaseCount,
    @@VERSION                                    AS FullVersion;

-----------------------------------------------------------------------
-- 3.2 SQL SERVER SERVICES INFORMATION
-----------------------------------------------------------------------
SELECT 
    servicename, 
    process_id, 
    startup_type_desc, 
    status_desc, 
    last_startup_time, 
    service_account, 
    is_clustered, 
    cluster_nodename, 
    [filename], 
    instant_file_initialization_enabled
FROM sys.dm_server_services WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 3.3 HARDWARE & SYSTEM INFORMATION
-----------------------------------------------------------------------
SELECT 
    cpu_count AS [Logical CPU Count], 
    scheduler_count, 
    (socket_count * cores_per_socket) AS [Physical Core Count], 
    socket_count AS [Socket Count], 
    cores_per_socket, 
    numa_node_count,
    physical_memory_kb/1024 AS [Physical Memory (MB)], 
    max_workers_count AS [Max Workers Count], 
    affinity_type_desc AS [Affinity Type], 
    sqlserver_start_time AS [SQL Server Start Time],
    DATEDIFF(hour, sqlserver_start_time, GETDATE()) AS [SQL Server Up Time (hrs)],
    virtual_machine_type_desc AS [Virtual Machine Type], 
    softnuma_configuration_desc AS [Soft NUMA Configuration], 
    sql_memory_model_desc, 
    container_type_desc
FROM sys.dm_os_sys_info WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 3.4 HOST INFORMATION (Linux/Container environments)
-----------------------------------------------------------------------
SELECT 
    host_platform, 
    host_distribution, 
    host_release, 
    host_service_pack_level, 
    host_sku, 
    os_language_version,
    host_architecture
FROM sys.dm_os_host_info WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 3.5 CLUSTER NODE INFORMATION (if in failover cluster)
-----------------------------------------------------------------------
SELECT 
    NodeName, 
    status_description, 
    is_current_owner
FROM sys.dm_os_cluster_nodes WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 3.6 SYSTEM MANUFACTURER (from SQL Server Error Log)
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'Manufacturer';

-----------------------------------------------------------------------
-- 3.7 BIOS DATE (from Windows Registry)
-----------------------------------------------------------------------
EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\BIOS', N'BiosReleaseDate';

-----------------------------------------------------------------------
-- 3.8 ACCELERATOR STATUS (GPU/Hardware acceleration)
-----------------------------------------------------------------------
SELECT 
    accelerator, 
    accelerator_desc, 
    config, 
    config_in_use, 
    mode, 
    mode_desc, 
    mode_reason, 
    mode_reason_desc, 
    accelerator_hardware_detected, 
    accelerator_library_version, 
    accelerator_driver_version
FROM sys.dm_server_accelerator_status WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- SECTION 4: MEMORY CONFIGURATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 MAX SERVER MEMORY vs. PHYSICAL MEMORY CHECK
-----------------------------------------------------------------------
SELECT
    CAST(sm.total_physical_memory_kb / 1048576.0
         AS DECIMAL(18,2))                        AS TotalPhysicalGB,
    CAST(c.value_in_use / 1024.0
         AS DECIMAL(18,2))                        AS MaxServerMemoryGB,
    CAST((sm.total_physical_memory_kb / 1024.0 - c.value_in_use)
         AS DECIMAL(18,0))                        AS MemoryLeftForOSMB,
    CASE
        WHEN c.value_in_use = 2147483647
            THEN '*** UNLIMITED — CONFIGURE NOW ***'
        WHEN (sm.total_physical_memory_kb / 1024.0 - c.value_in_use) < 2048
            THEN '*** LESS THAN 2 GB LEFT FOR OS ***'
        WHEN (sm.total_physical_memory_kb / 1024.0 - c.value_in_use) < 4096
            THEN '* Less than 4 GB left for OS *'
        ELSE 'OK'
    END                                           AS [Status]
FROM sys.dm_os_sys_memory sm
    CROSS JOIN sys.configurations c
WHERE c.[name] = 'max server memory (MB)';

-----------------------------------------------------------------------
-- SECTION 5: TEMPDB CONFIGURATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 TEMPDB FILE CONFIGURATION
--     Best practice: Multiple data files (1 per core, up to 8),
--     same initial size, same autogrowth.
-----------------------------------------------------------------------
SELECT
    [name]                                        AS FileName,
    type_desc                                     AS FileType,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS SizeMB,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR) + ' %'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR) + ' MB'
    END                                           AS AutoGrowth,
    physical_name
FROM sys.master_files
WHERE database_id = DB_ID('tempdb')
ORDER BY type_desc, [name];

-----------------------------------------------------------------------
-- 5.2 TEMPDB FILE COUNT RECOMMENDATION
-----------------------------------------------------------------------
SELECT
    COUNT(*)                                      AS TempdbDataFiles,
    (SELECT COUNT(*)
     FROM sys.dm_os_schedulers
     WHERE [status] = 'VISIBLE ONLINE')           AS OnlineCPUs,
    CASE
        WHEN COUNT(*) < LEAST(
            (SELECT COUNT(*)
             FROM sys.dm_os_schedulers
             WHERE [status] = 'VISIBLE ONLINE'), 8)
        THEN '*** ADD MORE TEMPDB DATA FILES ***'
        ELSE 'OK'
    END                                           AS Recommendation
FROM sys.master_files
WHERE database_id = DB_ID('tempdb')
  AND type_desc = 'ROWS';

-----------------------------------------------------------------------
-- SECTION 6: DEPRECATED FEATURES IN USE
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 DEPRECATED FEATURES USAGE COUNT
--     Monitor for features you need to migrate away from.
-----------------------------------------------------------------------
SELECT
    instance_name                         AS DeprecatedFeature,
    cntr_value                            AS UsageCount
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Deprecated Features%'
  AND cntr_value > 0
ORDER BY cntr_value DESC;


/*******************************************************************************
 * MISPLACED QUERIES - THESE SHOULD BE MOVED TO OTHER FILES
 *
 * The queries below were found in this file but don't belong in a 
 * configuration audit. Move them to the appropriate files indicated.
 ******************************************************************************/

-----------------------------------------------------------------------
-- QUERY 1: SUSPECT PAGES
-- SHOULD BE MOVED TO: database-integrity-checks.sql
-----------------------------------------------------------------------
/*
-- Look at Suspect Pages table (Query 24) (Suspect Pages)
SELECT DB_NAME(sp.database_id) AS [Database Name], 
       sp.[file_id], sp.page_id, sp.event_type, 
       sp.error_count, sp.last_update_date,
       mf.name AS [Logical Name], mf.physical_name AS [File Path]
FROM msdb.dbo.suspect_pages AS sp WITH (NOLOCK)
INNER JOIN sys.master_files AS mf WITH (NOLOCK)
ON mf.database_id = sp.database_id 
AND mf.file_id = sp.file_id
ORDER BY sp.database_id OPTION (RECOMPILE);

-- event_type value descriptions
-- 1 = 823 error caused by an operating system CRC error
--     or 824 error other than a bad checksum or a torn page (for example, a bad page ID)
-- 2 = Bad checksum
-- 3 = Torn page
-- 4 = Restored (The page was restored after it was marked bad)
-- 5 = Repaired (DBCC repaired the page)
-- 7 = Deallocated by DBCC

-- Ideally, this query returns no results. The table is limited to 1000 rows.
-- If you do get results here, you should do further investigation to determine the root cause

-- Manage the suspect_pages Table
-- https://bit.ly/2Fvr1c9
*/

-----------------------------------------------------------------------
-- QUERY 2: I/O WARNINGS FROM ERROR LOG
-- SHOULD BE MOVED TO: performance-io-latency.sql
-----------------------------------------------------------------------
/*
-- Read most recent entries from all SQL Server Error Logs (Query 25) (Error Log Entries)
DROP TABLE IF EXISTS #IOWarningResults;
CREATE TABLE #IOWarningResults (
    LogDate DATETIME, 
    ProcessInfo NVARCHAR(50), 
    LogText NVARCHAR(MAX)
);

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 1, 1, N'taking longer than 15 seconds';

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 2, 1, N'taking longer than 15 seconds';

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 3, 1, N'taking longer than 15 seconds';

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 4, 1, N'taking longer than 15 seconds';

INSERT INTO #IOWarningResults 
EXEC xp_readerrorlog 5, 1, N'taking longer than 15 seconds';

SELECT LogDate, ProcessInfo, LogText
FROM #IOWarningResults
ORDER BY LogDate DESC;

DROP TABLE IF EXISTS #IOWarningResults;

-- Finding 15 second I/O warnings in the SQL Server Error Log is useful evidence of
-- poor I/O performance (which might have many different causes)
-- Look to see if you see any patterns in the results (same files, same drives, same time of day, etc.)
*/

-----------------------------------------------------------------------
-- QUERY 3: TEMPDB VERSION STORE SPACE USAGE
-- SHOULD BE MOVED TO: performance-tempdb.sql
-----------------------------------------------------------------------
/*
-- Get tempdb version store space usage by database (Query 41) (Version Store Space Usage)
SELECT DB_NAME(database_id) AS [Database Name],
       reserved_page_count AS [Version Store Reserved Page Count], 
       reserved_space_kb/1024 AS [Version Store Reserved Space (MB)] 
FROM sys.dm_tran_version_store_space_usage WITH (NOLOCK) 
ORDER BY reserved_space_kb/1024 DESC OPTION (RECOMPILE);

-- sys.dm_tran_version_store_space_usage (Transact-SQL)
-- https://bit.ly/2vh3Bmk
*/

-----------------------------------------------------------------------
-- QUERY 4: TOP AVERAGE ELAPSED TIME QUERIES
-- SHOULD BE MOVED TO: performance-checking-queries.sql
-----------------------------------------------------------------------
/*
-- Get top average elapsed time queries for entire instance (Query 54) (Top Avg Elapsed Time Queries)
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name], 
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text],  
qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
qs.min_elapsed_time, qs.max_elapsed_time, qs.last_elapsed_time,
qs.execution_count AS [Execution Count],  
qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads], 
qs.total_physical_reads/qs.execution_count AS [Avg Physical Reads], 
qs.total_worker_time/qs.execution_count AS [Avg Worker Time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
qs.creation_time AS [Creation Time]
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_elapsed_time/qs.execution_count DESC OPTION (RECOMPILE);
*/

-----------------------------------------------------------------------
-- QUERY 5: TOP I/O STATEMENTS
-- SHOULD BE MOVED TO: performance-checking-queries.sql
-----------------------------------------------------------------------
/*
-- Lists the top statements by average input/output usage for the current database  (Query 70) (Top IO Statements)
SELECT TOP(50) OBJECT_NAME(qt.objectid, dbid) AS [SP Name],
(qs.total_logical_reads + qs.total_logical_writes) /qs.execution_count AS [Avg IO], 
qs.execution_count AS [Execution Count],
SUBSTRING(qt.[text],qs.statement_start_offset/2, 
    (CASE 
        WHEN qs.statement_end_offset = -1 
     THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
        ELSE qs.statement_end_offset 
     END - qs.statement_start_offset)/2) AS [Query Text]    
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qt.[dbid] = DB_ID()
ORDER BY [Avg IO] DESC OPTION (RECOMPILE);
*/

-----------------------------------------------------------------------
-- QUERY 6: INDEX USAGE STATISTICS
-- SHOULD BE MOVED TO: performance-index-and-statistics-maintenance.sql
-----------------------------------------------------------------------
/*
-- Index Read/Write stats (all tables in current DB) ordered by Reads  (Query 80) (Overall Index Usage - Reads)
SELECT SCHEMA_NAME(t.[schema_id]) AS [SchemaName], 
       OBJECT_NAME(i.[object_id]) AS [ObjectName], 
       i.[name] AS [IndexName], 
       i.index_id, 
       i.[type_desc] AS [Index Type],
       s.user_seeks, 
       s.user_scans, 
       s.user_lookups,
       s.user_seeks + s.user_scans + s.user_lookups AS [Total Reads], 
       s.user_updates AS [Writes],  
       i.fill_factor AS [Fill Factor], 
       i.has_filter, 
       i.filter_definition, 
       s.last_user_scan, 
       s.last_user_lookup, 
       s.last_user_seek, 
       i.[allow_page_locks]
FROM sys.indexes AS i WITH (NOLOCK)
LEFT OUTER JOIN sys.dm_db_index_usage_stats AS s WITH (NOLOCK)
ON i.[object_id] = s.[object_id]
AND i.index_id = s.index_id
AND s.database_id = DB_ID()
INNER JOIN sys.tables AS t WITH (NOLOCK)
ON i.[object_id] = t.[object_id]
WHERE OBJECTPROPERTY(i.[object_id],'IsUserTable') = 1
ORDER BY s.user_seeks + s.user_scans + s.user_lookups DESC OPTION (RECOMPILE);
*/

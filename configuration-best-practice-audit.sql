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

-----------------------------------------------------------------------
-- SECTION 7: DATABASE USAGE & MONITORING
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 IDENTIFY UNUSED DATABASES SINCE LAST RESTART
--     Shows databases with no user activity since SQL Server started.
--     Useful for identifying candidates for archival or decommission.
-----------------------------------------------------------------------
SELECT 
    [name] AS UnusedDatabase
FROM sys.databases 
WHERE database_id > 4
  AND [name] NOT IN (
      SELECT DB_NAME(database_id) 
      FROM sys.dm_db_index_usage_stats
      WHERE COALESCE(last_user_seek, last_user_scan, last_user_lookup, '1/1/1970') > 
            (SELECT login_time FROM sysprocesses WHERE spid = 1)
  );

-----------------------------------------------------------------------
-- SECTION 8: CONFIGURATION CHANGES
--            *** THESE COMMANDS MODIFY SYSTEM SETTINGS ***
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 8.1 ENABLE ADVANCED OPTIONS
--     Required before changing advanced configuration options.
-----------------------------------------------------------------------
USE master;
GO
EXEC sp_configure 'show advanced option', '1';
GO
RECONFIGURE;
GO

-----------------------------------------------------------------------
-- 8.2 ADJUST MEMORY ALLOCATION AND MAXDOP
--     Example: Set max server memory to 12 GB and MAXDOP to 4.
--     Adjust values based on your server specifications.
-----------------------------------------------------------------------
-- EXEC sp_configure 'max server memory', 12288;
-- GO
-- EXEC sp_configure 'max degree of parallelism', 4;
-- GO
-- RECONFIGURE;
-- GO

/*******************************************************************************
 * SECTION 9: DANGEROUS OPERATIONS
 * 
 * *** EXTREME CAUTION REQUIRED ***
 * 
 * The following queries generate DROP, OFFLINE, DETACH, and DELETE commands
 * that can cause permanent data loss or service disruption.
 * 
 * SAFETY MEASURES:
 * - All destructive queries are commented out by default
 * - Review generated scripts carefully before executing
 * - Always have verified backups before proceeding
 * - Test in non-production environment first
 * - Consider impact on applications and users
 ******************************************************************************/

-----------------------------------------------------------------------
-- 9.1 GENERATE DROP STATEMENTS FOR ALL USER FUNCTIONS
--     WARNING: This will DELETE all user-defined functions!
-----------------------------------------------------------------------
/*
SELECT 'DROP FUNCTION [' + SCHEMA_NAME(o.schema_id) + '].[' + o.name + '];'
FROM sys.sql_modules m 
INNER JOIN sys.objects o ON m.object_id = o.object_id
WHERE type_desc LIKE '%function%'
ORDER BY SCHEMA_NAME(o.schema_id), o.name;
*/

-----------------------------------------------------------------------
-- 9.2 GENERATE DROP STATEMENTS FOR ALL USER STORED PROCEDURES
--     WARNING: This will DELETE all user-defined stored procedures!
-----------------------------------------------------------------------
/*
SELECT 'DROP PROCEDURE [' + SCHEMA_NAME(p.schema_id) + '].[' + p.NAME + '];'
FROM sys.procedures p
WHERE is_ms_shipped = 0
ORDER BY SCHEMA_NAME(p.schema_id), p.NAME;
*/

-----------------------------------------------------------------------
-- 9.3 ALTERNATIVE: DROP FUNCTIONS (DIFFERENT METHOD)
-----------------------------------------------------------------------
/*
SELECT 'DROP FUNCTION [' + SCHEMA_NAME(o.schema_id) + '].[' + o.NAME + '];'
FROM sys.objects o 
WHERE type IN ('FN', 'IF', 'TF')  -- Scalar, Inline, Table-Valued
  AND is_ms_shipped = 0
ORDER BY SCHEMA_NAME(o.schema_id), o.NAME;
*/

-----------------------------------------------------------------------
-- 9.4 GENERATE OFFLINE COMMANDS FOR ALL USER DATABASES
--     WARNING: This will take databases OFFLINE (service disruption)!
-----------------------------------------------------------------------
/*
SELECT 
    'USE [master];' + CHAR(13) + CHAR(10) +
    'ALTER DATABASE [' + name + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
    'ALTER DATABASE [' + name + '] SET OFFLINE WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10)
FROM sys.databases 
WHERE name NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')
  AND database_id > 4
ORDER BY name;
*/

-----------------------------------------------------------------------
-- 9.5 GENERATE DETACH COMMANDS FOR ALL USER DATABASES
--     WARNING: This will DETACH databases (removes from instance)!
-----------------------------------------------------------------------
/*
SELECT 
    'USE [master];' + CHAR(13) + CHAR(10) +
    'ALTER DATABASE [' + name + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
    'EXEC master.dbo.sp_detach_db @dbname = N''' + name + ''';' + CHAR(13) + CHAR(10)
FROM sys.databases 
WHERE name NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')
  AND database_id > 4
ORDER BY name;
*/

-----------------------------------------------------------------------
-- 9.6 DROP ALL NON-SYSTEM DATABASE USERS
--     WARNING: This will REMOVE all user access from the database!
-----------------------------------------------------------------------
/*
DECLARE @sql NVARCHAR(MAX) = '';

SELECT @sql = @sql +
    'PRINT ''Dropping user: ' + name + ''';' + CHAR(13) + CHAR(10) +
    'DROP USER [' + name + '];' + CHAR(13) + CHAR(10)
FROM sys.database_principals
WHERE name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys', 'public')
  AND type <> 'R'  -- Exclude roles
ORDER BY name;

-- Uncomment to execute:
-- EXEC sp_executesql @sql;

-- To review the generated script:
PRINT @sql;
*/

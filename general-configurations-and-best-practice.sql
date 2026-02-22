/*******************************************************************************
 * SQL SERVER ADMINISTRATION & CONFIGURATION GUIDE
 * 
 * Purpose: Comprehensive collection of SQL Server administration queries
 *          covering configuration, monitoring, diagnostics, and troubleshooting.
 * 
 * Sections:
 *   1. ERROR LOGS & DIAGNOSTICS
 *   2. TROUBLESHOOTING & RECOVERY
 *   3. MEMORY & RESOURCE CONFIGURATION
 *   4. DATABASE CONFIGURATION, SETTINGS & MONITORING
 *   5. SYSTEM COMMANDS (xp_cmdshell)
 *   6. DANGEROUS OPERATIONS (CAUTION REQUIRED)
 *   7. INSTANCE CONFIGURATION & BEST PRACTICES
 * 
 * Safety:  Most queries are read-only. Modification queries are clearly marked.
 * 
 * Note:    Recommended values are general-purpose starting points.
 *          Always adjust for your specific workload and environment.
 ******************************************************************************/

USE MASTER;
GO

/*******************************************************************************
   SECTION 1: ERROR LOGS & DIAGNOSTICS
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 SEARCH ERROR LOGS FOR SPECIFIC STRING
--     Quick search for login failures or other events
-----------------------------------------------------------------------
-- Example: Search for login failures
-- EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';
-- GO

-----------------------------------------------------------------------
-- 1.2 COMPREHENSIVE ERROR LOG SEARCH
--     Search all available error log files for a specific string
--     Enumerates all log files and searches each one
-----------------------------------------------------------------------
/*
SET NOCOUNT ON;

DECLARE @log_number INT,
        @search_string VARCHAR(255) = '<search_string>';  -- Replace with your search term

DROP TABLE IF EXISTS #error_log;

CREATE TABLE #error_log
(
    log_number INT NOT NULL,
    log_date DATE NOT NULL,
    log_size INT NOT NULL
);

DROP TABLE IF EXISTS #sp_readerrorlog_output;

CREATE TABLE #sp_readerrorlog_output
(
    LogDate DATETIME2 NOT NULL,
    ProcessInfo VARCHAR(255) NOT NULL,
    Text VARCHAR(255) NOT NULL
);

INSERT #error_log
(
    log_number,
    log_date,
    log_size
)
EXEC ('EXEC sys.sp_enumerrorlogs;');

DECLARE log_cur CURSOR LOCAL FAST_FORWARD FOR
SELECT el.log_number
FROM #error_log AS el
ORDER BY el.log_number
FOR READ ONLY;

OPEN log_cur;
FETCH log_cur
INTO @log_number;

WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #sp_readerrorlog_output
    (
        LogDate,
        ProcessInfo,
        Text
    )
    EXEC sp_readerrorlog @p1 = @log_number, @p2 = 1, @p3 = @search_string;

    FETCH log_cur
    INTO @log_number;
END;

CLOSE log_cur;
DEALLOCATE log_cur;

SELECT LogDate,
       ProcessInfo,
       Text
FROM #sp_readerrorlog_output
ORDER BY LogDate DESC;
*/




/*******************************************************************************
   SECTION 2: TROUBLESHOOTING & RECOVERY
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 EMERGENCY SA PASSWORD RECOVERY
--     Use when SQL Server instance is inaccessible and sa password unknown
--     Requires local Administrator access on the Windows server
--     *** EMERGENCY PROCEDURE ONLY ***
-----------------------------------------------------------------------
/*
   PROCEDURE:
   
   1. Stop SQL Server service (if running)
   
   2. Start SQL Server in single-user mode with SQLCMD parameter:
      C:\Windows\system32> net start MSSQLSERVER /mSQLCMD
      
      Output:
      The SQL Server (MSSQLSERVER) service is starting.
      The SQL Server (MSSQLSERVER) service was started successfully.
   
   3. Connect using Windows Authentication and create/promote login:
      C:\Windows\system32> sqlcmd -S. -E
      1> CREATE LOGIN [domain\username] FROM WINDOWS;
      2> ALTER SERVER ROLE sysadmin ADD MEMBER [domain\username];
      3> GO
   
   4. Restart SQL Server normally:
      C:\Windows\system32> net stop MSSQLSERVER
      C:\Windows\system32> net start MSSQLSERVER
*/

-----------------------------------------------------------------------
-- 2.2 EMERGENCY REPAIR FOR FILESTREAM RECOVERY PENDING
--     Fix databases stuck in Recovery Pending after Windows Update
--     *** EMERGENCY PROCEDURE - CAN CAUSE DATA LOSS ***
--     Part of SQL Server DBA Toolbox:
--     https://github.com/DavidSchanzer/Sql-Server-DBA-Toolbox
-----------------------------------------------------------------------
/*
-- This script avoids having to perform a database restore when Windows 
-- patching causes a FileStream-enabled database to enter Recovery Pending state.
-- Replace all <DBName> with the relevant database name.

USE [master];
GO

EXEC sp_configure @configname = 'filestream access level', @configvalue = 2;
RECONFIGURE WITH OVERRIDE;
GO

ALTER DATABASE <DBName> SET EMERGENCY;
GO

ALTER DATABASE <DBName> SET SINGLE_USER;
GO

DBCC CHECKDB(<DBName>, REPAIR_ALLOW_DATA_LOSS) WITH ALL_ERRORMSGS;
GO

ALTER DATABASE <DBName> SET MULTI_USER;
GO
*/


/*******************************************************************************
   SECTION 3: MEMORY & RESOURCE CONFIGURATION
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 MAX SERVER MEMORY vs. PHYSICAL MEMORY CHECK
--     Verify adequate memory is left for the operating system
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
-- 3.2 TEMPDB FILE CONFIGURATION
--     Best practice: Multiple data files (1 per core, up to 8)
--     All files should have same initial size and autogrowth settings
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
-- 3.3 TEMPDB FILE COUNT RECOMMENDATION
--     Check if number of tempdb files matches best practices
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

/*******************************************************************************
   SECTION 4: DATABASE CONFIGURATION, SETTINGS & MONITORING
*******************************************************************************/

-----------------------------------------------------------------------
-- 4.1 DATABASE SETTINGS AUDIT
--     Review all database settings and flag common misconfigurations
--     (auto-close, auto-shrink, non-CHECKSUM page verify, etc.)
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
-- 4.2 DATABASE SCOPED CONFIGURATIONS (SQL Server 2016+)
--     Review database-level configuration overrides
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
-- 4.3 ENABLE QUERY STORE WITH RECOMMENDED SETTINGS
--     Query Store helps track query performance over time
--     *** MODIFIES DATABASE SETTINGS ***
--     Reference: https://www.sqlskills.com/blogs/erin/query-store-settings/
-----------------------------------------------------------------------

-- Enable Query Store
ALTER DATABASE [YourDatabaseName] SET QUERY_STORE = ON;
GO

-- Configure Query Store settings (for SQL Server 2016 & 2017)
ALTER DATABASE [YourDatabaseName]
SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200,
    MAX_STORAGE_SIZE_MB = 128,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 60
);
GO

-----------------------------------------------------------------------
-- 4.4 IDENTIFY UNUSED DATABASES SINCE LAST RESTART
--     Shows databases with no user activity since SQL Server started
--     Useful for identifying candidates for archival or decommission
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
-- 4.5 DEPRECATED FEATURES USAGE COUNT
--     Monitor for features you need to migrate away from
--     Check these against Microsoft's deprecation timeline
-----------------------------------------------------------------------
SELECT
    instance_name                         AS DeprecatedFeature,
    cntr_value                            AS UsageCount
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Deprecated Features%'
  AND cntr_value > 0
ORDER BY cntr_value DESC;



/*******************************************************************************
   SECTION 5: SYSTEM COMMANDS (xp_cmdshell)
   
   WARNING: xp_cmdshell must be enabled and should only be used by authorized
            administrators. These commands execute with SQL Server service account
            privileges. Enable only when needed and disable immediately after use.
*******************************************************************************/

-----------------------------------------------------------------------
-- 5.1 ENABLE xp_cmdshell
--     Required before executing OS commands
--     *** SECURITY RISK - DISABLE AFTER USE ***
-----------------------------------------------------------------------
/*
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 5.2 DISABLE xp_cmdshell
--     Disable when no longer needed
-----------------------------------------------------------------------
/*
EXEC sp_configure 'xp_cmdshell', 0;
RECONFIGURE;
GO

EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 5.3 EXECUTE DIRECTORY LISTING
--     Example of OS command execution
-----------------------------------------------------------------------
-- EXEC xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 5.4 MAP NETWORK SHARE
--     Map a network drive for backup/restore operations
--     *** STORES CREDENTIALS - USE WITH CAUTION ***
-----------------------------------------------------------------------
/*
-- Map network share T: with credentials
EXEC xp_cmdshell 'net use T: \\10.216.224.25\shared password123 /USER:builtin\dbbackup';
GO

-- Verify mapping
EXEC xp_cmdshell 'dir T:\';
GO

-- Disconnect mapped drive
EXEC xp_cmdshell 'net use T: /delete';
GO
*/


/*******************************************************************************
   SECTION 6: DANGEROUS OPERATIONS (CAUTION REQUIRED)
   
   *** EXTREME CAUTION REQUIRED ***
   
   The following queries generate DROP, OFFLINE, DETACH, and DELETE commands
   that can cause permanent data loss or service disruption.
   
   SAFETY MEASURES:
   - All destructive queries are commented out by default
   - Review generated scripts carefully before executing
   - Always have verified backups before proceeding
   - Test in non-production environment first
   - Consider impact on applications and users
   - Execute during approved maintenance windows only
*******************************************************************************/

-----------------------------------------------------------------------
-- 6.1 GENERATE DROP STATEMENTS FOR ALL USER FUNCTIONS
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
-- 6.2 GENERATE DROP STATEMENTS FOR ALL USER STORED PROCEDURES
--     WARNING: This will DELETE all user-defined stored procedures!
-----------------------------------------------------------------------
/*
SELECT 'DROP PROCEDURE [' + SCHEMA_NAME(p.schema_id) + '].[' + p.NAME + '];'
FROM sys.procedures p
WHERE is_ms_shipped = 0
ORDER BY SCHEMA_NAME(p.schema_id), p.NAME;
*/

-----------------------------------------------------------------------
-- 6.3 ALTERNATIVE: DROP FUNCTIONS (DIFFERENT METHOD)
-----------------------------------------------------------------------
/*
SELECT 'DROP FUNCTION [' + SCHEMA_NAME(o.schema_id) + '].[' + o.NAME + '];'
FROM sys.objects o 
WHERE type IN ('FN', 'IF', 'TF')  -- Scalar, Inline, Table-Valued
  AND is_ms_shipped = 0
ORDER BY SCHEMA_NAME(o.schema_id), o.NAME;
*/

-----------------------------------------------------------------------
-- 6.4 GENERATE OFFLINE COMMANDS FOR ALL USER DATABASES
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
-- 6.5 GENERATE DETACH COMMANDS FOR ALL USER DATABASES
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
-- 6.6 DROP ALL NON-SYSTEM DATABASE USERS
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


/*******************************************************************************
   SECTION 7: INSTANCE CONFIGURATION & BEST PRACTICES
*******************************************************************************/

-----------------------------------------------------------------------
-- 7.1 KEY sys.configurations SETTINGS WITH RECOMMENDATIONS
--     Review critical instance settings against best practices
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
-- 7.2 ALL INSTANCE CONFIGURATIONS (COMPLETE LIST)
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
-- 7.3 TRACE FLAGS CURRENTLY ENABLED
--     Monitor active trace flags affecting server behavior
-----------------------------------------------------------------------
DBCC TRACESTATUS(-1);

-----------------------------------------------------------------------
-- 7.4 ENABLE ADVANCED OPTIONS
--     Required before changing advanced configuration options
--     *** MODIFIES SYSTEM SETTINGS ***
-----------------------------------------------------------------------
-- EXEC sp_configure 'show advanced option', '1';
-- GO
-- RECONFIGURE;
-- GO

-----------------------------------------------------------------------
-- 7.5 ADJUST MEMORY ALLOCATION AND MAXDOP
--     Example: Set max server memory to 12 GB and MAXDOP to 4
--     *** MODIFIES SYSTEM SETTINGS ***
--     Adjust values based on your server specifications
-----------------------------------------------------------------------
-- EXEC sp_configure 'max server memory', 12288;
-- GO
-- EXEC sp_configure 'max degree of parallelism', 4;
-- GO
-- RECONFIGURE;
-- GO


/*******************************************************************************
   END OF FILE
   
   This file was merged from:
   - configuration-best-practice-audit.sql
   - general-administration-queries.sql
   
   Last reorganized: February 22, 2026
*******************************************************************************/

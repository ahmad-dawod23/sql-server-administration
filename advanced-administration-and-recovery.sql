/*******************************************************************************
 * SQL SERVER ADVANCED ADMINISTRATION & RECOVERY
 *
 * Purpose: Specialized SQL Server administration procedures for error-log
 *          diagnostics, instance configuration, service startup failure
 *          triage, emergency recovery, operating system integration, and
 *          high-risk database operations.
 *
 * Sections:
 *   1. ERROR LOG DIAGNOSTICS
 *   2. INSTANCE CONFIGURATION & TRACE FLAGS
 *   3. SERVICE STARTUP FAILURE: CAUSES & DIAGNOSTICS
 *   4. EMERGENCY RECOVERY PROCEDURES
 *   5. OPERATING SYSTEM COMMANDS (xp_cmdshell)
 *   6. DATABASE OBJECT & USER REMOVAL
 *   7. DATABASE LIFECYCLE OPERATIONS
 *
 * Safety:  Section 1, the trace-flag query in Section 2, and the diagnostic
 *          queries in Section 3 are read-only. All configuration, recovery,
 *          OS, and destructive operations are commented out by default and
 *          clearly marked.
 *
 * Note:    Review placeholders and generated commands before execution. Test
 *          changes outside production and maintain verified backups.
 ******************************************************************************/

/*******************************************************************************
   SECTION 1: ERROR LOG DIAGNOSTICS
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 SEARCH THE CURRENT ERROR LOG
--     Quick search for login failures or other events
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';
-- GO

-----------------------------------------------------------------------
-- 1.2 SEARCH ALL AVAILABLE ERROR LOGS
--     Enumerate the archived logs and search each for a specific string
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
    EXEC sys.sp_readerrorlog @p1 = @log_number, @p2 = 1, @p3 = @search_string;

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
   SECTION 2: INSTANCE CONFIGURATION & TRACE FLAGS
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 TRACE FLAGS CURRENTLY ENABLED
--     Monitor active trace flags affecting server behavior
--     READ-ONLY
-----------------------------------------------------------------------
DBCC TRACESTATUS(-1);
GO

-----------------------------------------------------------------------
-- 2.2 ENABLE ADVANCED CONFIGURATION OPTIONS
--     Required before changing advanced configuration options
--     *** MODIFIES INSTANCE SETTINGS ***
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 2.3 ADJUST MEMORY ALLOCATION AND MAXDOP
--     Example: Set max server memory to 12 GB and MAXDOP to 4
--     *** MODIFIES INSTANCE SETTINGS ***
--     Adjust values for the server specifications and workload
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'max server memory (MB)', 12288;
EXEC sys.sp_configure 'max degree of parallelism', 4;
RECONFIGURE;
GO
*/


/*******************************************************************************
   SECTION 3: SERVICE STARTUP FAILURE: CAUSES & DIAGNOSTICS

   Reference summary of common causes preventing the SQL Server (Database
   Engine) or SQL Server Agent service from starting, followed by read-only
   diagnostic queries that surface the most frequent culprits. Use this
   section as a first pass when an instance is down or repeatedly recycling.
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 COMMON CAUSES OF SERVICE STARTUP FAILURE (REFERENCE)
-----------------------------------------------------------------------
/*
   I. SYSTEM PREREQUISITES & CONFIGURATION
      - Service start mode manually set to Disabled.
      - Invalid/misconfigured configuration value; troubleshoot by starting
        with minimal configuration (sqlservr.exe -f, or startup parameter -f).
      - Corrupt or missing application files, Registry settings, or bad
        configuration parameter values.
      - Service account cannot access the SQL Server portion of the Registry.
      - A pending Windows restart blocks Setup/component initialization.
      - WMI service not running, or an invalid MSCluster WMI namespace,
        blocks install/repair/update.
      - Missing .NET Framework components prevent component initialization.
      - OS missing a required service pack or security update.

   II. NETWORKING & PROTOCOL INITIALIZATION
      - TLS/SSL mismatch between server and client during the pre-login
        handshake causes connection/handshake failures.
      - No valid certificate, or failure creating a self-signed certificate,
        causes SSL initialization failure (Error 17182) and prevents the
        network library from starting (Error 17826).
      - Net-Library load failure: "Could not set up Net-Library 'SSNETLIB'"
        (Error 17826) and Error 17059.
      - TCP port already in use by another process (Error 26023, 9692).
      - Winsock Layered Service Providers (LSPs) loaded in the SQL Server
        address space cause abrupt network termination or service failure.

   III. PERMISSIONS & SERVICE ACCOUNT
      - Service account password expired (enable "Password Never Expires" or
        move to a Group Managed Service Account (gMSA)).
      - Missing "Log on as a service" right (SeServiceLogonRight) -> Error 7034.
      - gMSA has not yet authenticated with the domain at boot, causing a
        transient startup failure that may succeed on retry.
      - Insufficient NTFS permissions on relocated data/log files -> service
        starts then stops.
      - Antivirus on-access scanning locks SQL Server files, causing "File
        activation failure" or "Unable to open the physical file".

   IV. DATABASE INTEGRITY & RESOURCES
      - master database damaged/corrupt -> rebuild system databases via
        Setup /ACTION=REBUILDDATABASE, or start in single-user mode and
        restore master from a known-good backup.
      - Database file access error (945) during recovery (e.g. SSISDB during
        an upgrade) can fail master recovery -> Error 3417, service shuts down.
      - Automatic recovery hits a resource-related error -> database enters
        RECOVERY_PENDING.
      - Transaction log fills during recovery -> database marked RESOURCE
        PENDING.
      - Data access/read error or a detected torn page during recovery ->
        database marked SUSPECT.
      - tempdb cannot be created (missing directory structure, or files
        cannot be opened/created -> Error 17204, 5120, 1802) -> instance
        will not start.
      - Invalid default data/log file location in the registry -> Error
        0x851A0043 / 0x851A0044.
      - Instance out of resources: memory, locks, or disk space (Severity 17).
      - Worker thread exhaustion (THREADPOOL waits) -> instance unresponsive,
        new connections rejected except possibly via the Dedicated
        Administrator Connection (DAC).

   V. INSTALLATION & UPGRADE FAILURES
      - "Could not find the Database Engine startup handle" (Error 0x851A0019).
      - "Wait on the Database Engine recovery handle failed" (Error
        0x851A001A / 3417) — common after a failed CU/SP install.
      - Prior installation left partial/incomplete without automatic rollback.
      - Running an expired evaluation edition.
      - Upgrade (T-SQL) script failures during the post-binary recovery
        phase: missing required support files (Error 4860), a configuration
        statement inside a transaction (Error 574), missing required logins
        or users (Error 15151), or failure to drop server principals/
        certificates that still have granted permissions or mapped users
        (Error 15173 / 15559). Typically surfaces as fatal Errors 912/3417.

   VI. ENVIRONMENT & HARDWARE
      - I/O errors during disk access (Error 825, 833) -> check disk
        subsystem health.
      - Volume uses an unsupported sector size (e.g. 8192 bytes) -> Error 5178.
      - Critical hardware failure (failed disk or other component).
      - Insufficient disk space (OS error 112) can mark a database SUSPECT.
      - Clustered instance: dependent resources (IP address, DNS name,
        shared disk) offline -> the SQL Server resource cannot come online.
      - WSFC quorum loss (network issue or witness failure) shuts down the
        Cluster service.
      - Cluster validation failures block Setup or Cluster-Aware Updating.
      - AG/FCI automatic failover: a lease time-out (system overload or a
        process dump) or health-check time-out can terminate the current
        primary or block startup on the secondary.
      - Cluster resource exceeded the maximum failover threshold in the
        configured period -> replica remains failed/resolving.
      - Non-Microsoft in-process software (e.g. an Oracle OLE DB provider
        via a linked server query) can crash the service (heap corruption).
      - SQL Server Launchpad may fail to start if OS updates change the
        behavior of APIs it depends on.

   VII. RELATED SERVICE: SQL SERVER AGENT
      - SQLServerAgent depends on the Database Engine service and cannot
        start while it is down.
      - Agent startup type often defaults to Manual; set to Automatic if
        scheduled jobs must run without manual intervention.
      - Do not start the Agent while the engine is running in single-user
        mode (-m) — it will consume the only available connection.
      - Agent fails to start if its service account password has expired.
      - Agent fails to start if a relocated Agent error log path is invalid
        or missing.
*/

-----------------------------------------------------------------------
-- 3.2 CHECK REGISTRY-BASED STARTUP PARAMETERS
--     Surfaces -f (minimal config), -m (single user), -T (trace flags),
--     and other parameters configured outside SQL Server Configuration
--     Manager's normal startup
--     READ-ONLY
-----------------------------------------------------------------------
SELECT registry_key,
       value_name,
       value_data
FROM sys.dm_server_registry
WHERE registry_key LIKE '%Parameters%'
ORDER BY value_name;
GO

-----------------------------------------------------------------------
-- 3.3 CHECK SYSTEM & USER DATABASE STATE
--     Flags RECOVERY_PENDING, SUSPECT, RESTORING, or STANDBY databases
--     that can prevent the instance from being considered fully available
--     READ-ONLY
-----------------------------------------------------------------------
SELECT name,
       database_id,
       state_desc,
       recovery_model_desc,
       is_in_standby,
       is_read_only
FROM sys.databases
ORDER BY database_id;
GO

-----------------------------------------------------------------------
-- 3.4 CHECK TEMPDB FILE LOCATIONS AND STATE
--     Confirms tempdb files exist and their target directories are valid;
--     a missing directory or path prevents the instance from starting
--     READ-ONLY
-----------------------------------------------------------------------
SELECT name,
       physical_name,
       state_desc,
       size * 8 / 1024 AS size_mb
FROM sys.master_files
WHERE database_id = DB_ID(N'tempdb');
GO

-----------------------------------------------------------------------
-- 3.5 CHECK FOR WORKER THREAD (THREADPOOL) EXHAUSTION
--     Non-zero, growing THREADPOOL wait time suggests the instance may
--     become unresponsive to new connections
--     READ-ONLY
-----------------------------------------------------------------------
SELECT wait_type,
       waiting_tasks_count,
       wait_time_ms,
       signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type = N'THREADPOOL';
GO

-----------------------------------------------------------------------
-- 3.6 CHECK PHYSICAL MEMORY STATE AND MEMORY CONFIGURATION
--     Correlates OS-reported memory pressure with min/max server memory
--     READ-ONLY
-----------------------------------------------------------------------
SELECT total_physical_memory_kb / 1024 AS total_physical_memory_mb,
       available_physical_memory_kb / 1024 AS available_physical_memory_mb,
       system_memory_state_desc
FROM sys.dm_os_sys_memory;
GO

SELECT name,
       value,
       value_in_use
FROM sys.configurations
WHERE name IN (N'min server memory (MB)', N'max server memory (MB)');
GO

-----------------------------------------------------------------------
-- 3.7 CHECK AVAILABLE DISK SPACE FOR DATA, LOG, AND TEMPDB VOLUMES
--     Low free space (OS error 112) can prevent recovery and mark a
--     database SUSPECT
--     READ-ONLY
-----------------------------------------------------------------------
SELECT DISTINCT vs.volume_mount_point,
       vs.total_bytes / 1024 / 1024 / 1024 AS total_gb,
       vs.available_bytes / 1024 / 1024 / 1024 AS free_gb
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;
GO

-----------------------------------------------------------------------
-- 3.8 CHECK WSFC / AVAILABILITY GROUP CLUSTER HEALTH
--     Relevant for FCI and Always On Availability Group instances only;
--     returns empty result sets on a standalone instance
--     READ-ONLY
-----------------------------------------------------------------------
SELECT *
FROM sys.dm_os_cluster_nodes;
GO

SELECT *
FROM sys.dm_hadr_cluster;
GO

-----------------------------------------------------------------------
-- 3.9 CHECK SQL SERVER AND SQL SERVER AGENT SERVICE STATE
--     QUERYSTATE is a read-only xp_servicecontrol action; adjust the
--     service display name if the instance is named (e.g. MSSQL$INSTANCE)
--     READ-ONLY
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_servicecontrol 'QUERYSTATE', 'MSSQLSERVER';
-- EXEC master.dbo.xp_servicecontrol 'QUERYSTATE', 'SQLSERVERAGENT';
-- GO

-----------------------------------------------------------------------
-- 3.10 SEARCH THE ERROR LOG FOR COMMON STARTUP FAILURE SIGNATURES
--      Pair with Section 1.2 to sweep every archived log for these terms
--      READ-ONLY
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'recovery is', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'suspect', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'tempdb', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'17204', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'3417', NULL, NULL, NULL, N'desc';
-- GO


/*******************************************************************************
   SECTION 4: EMERGENCY RECOVERY PROCEDURES

   WARNING: Use these procedures only during a verified emergency. Confirm that
            current, restorable backups exist before attempting database repair.
*******************************************************************************/

-----------------------------------------------------------------------
-- 4.1 RESTORE SYSADMIN ACCESS IN SINGLE-USER MODE
--     Use when the instance is inaccessible and no sysadmin login is available
--     Requires local Administrator access on the Windows server
--     *** EMERGENCY PROCEDURE ONLY ***
-----------------------------------------------------------------------
/*
   PROCEDURE:

   1. Stop the SQL Server service, if it is running.

   2. Start SQL Server in single-user mode and reserve the connection for SQLCMD:
      C:\Windows\system32> net start MSSQLSERVER /mSQLCMD

   3. Connect with Windows Authentication and create or promote a login:
      C:\Windows\system32> sqlcmd -S. -E
      1> CREATE LOGIN [domain\username] FROM WINDOWS;
      2> ALTER SERVER ROLE sysadmin ADD MEMBER [domain\username];
      3> GO

   4. Restart SQL Server normally:
      C:\Windows\system32> net stop MSSQLSERVER
      C:\Windows\system32> net start MSSQLSERVER
*/

-----------------------------------------------------------------------
-- 4.2 REPAIR A FILESTREAM DATABASE IN RECOVERY_PENDING
--     Last-resort procedure for a FileStream-enabled database that enters
--     RECOVERY_PENDING after Windows patching
--     *** CAN CAUSE DATA LOSS ***
--     Source: https://github.com/DavidSchanzer/Sql-Server-DBA-Toolbox
-----------------------------------------------------------------------
/*
-- Replace every <DBName> placeholder with the affected database name.

USE [master];
GO

EXEC sys.sp_configure @configname = 'filestream access level', @configvalue = 2;
RECONFIGURE WITH OVERRIDE;
GO

ALTER DATABASE <DBName> SET EMERGENCY;
GO

ALTER DATABASE <DBName> SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

DBCC CHECKDB (<DBName>, REPAIR_ALLOW_DATA_LOSS) WITH ALL_ERRORMSGS;
GO

ALTER DATABASE <DBName> SET MULTI_USER;
GO
*/


/*******************************************************************************
   SECTION 5: OPERATING SYSTEM COMMANDS (xp_cmdshell)

   WARNING: xp_cmdshell executes with SQL Server service-account privileges.
            Enable it only for an approved task and disable it immediately after.
*******************************************************************************/

-----------------------------------------------------------------------
-- 5.1 ENABLE xp_cmdshell
--     *** SECURITY-SENSITIVE INSTANCE CHANGE ***
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sys.sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 5.2 RUN A DIRECTORY LISTING
--     Simple example of operating-system command execution
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 5.3 MAP, VERIFY, AND DISCONNECT A NETWORK SHARE
--     Prefer a UNC path when the calling feature supports it
--     *** DO NOT STORE REAL CREDENTIALS IN THIS SCRIPT ***
-----------------------------------------------------------------------
/*
-- Replace all placeholders before use.
EXEC master.dbo.xp_cmdshell 'net use T: \\<server>\<share> <password> /USER:<domain>\<account>';
GO

EXEC master.dbo.xp_cmdshell 'dir T:\';
GO

EXEC master.dbo.xp_cmdshell 'net use T: /delete';
GO
*/

-----------------------------------------------------------------------
-- 5.4 DISABLE xp_cmdshell
--     Restore the secure configuration immediately after use
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'xp_cmdshell', 0;
RECONFIGURE;
GO

EXEC sys.sp_configure 'show advanced options', 0;
RECONFIGURE;
GO
*/


/*******************************************************************************
   SECTION 6: DATABASE OBJECT & USER REMOVAL

   *** EXTREME CAUTION REQUIRED ***

   Run these generators in the intended user database, not [master]. They return
   commands for review; they do not execute the generated commands directly.
*******************************************************************************/

-----------------------------------------------------------------------
-- 6.1 GENERATE DROP COMMANDS FOR ALL USER-DEFINED FUNCTIONS
--     Includes scalar, inline table-valued, and table-valued functions
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP FUNCTION ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' +
       QUOTENAME(o.name) + N';' AS drop_command
FROM sys.objects AS o
WHERE o.type IN ('FN', 'IF', 'TF')
  AND o.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(o.schema_id),
         o.name;
*/

-----------------------------------------------------------------------
-- 6.2 GENERATE DROP COMMANDS FOR ALL USER-DEFINED STORED PROCEDURES
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP PROCEDURE ' + QUOTENAME(SCHEMA_NAME(p.schema_id)) + N'.' +
       QUOTENAME(p.name) + N';' AS drop_command
FROM sys.procedures AS p
WHERE p.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(p.schema_id),
         p.name;
*/

-----------------------------------------------------------------------
-- 6.3 GENERATE DROP COMMANDS FOR NON-SYSTEM DATABASE USERS
--     Excludes fixed roles and standard system principals
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP USER ' + QUOTENAME(dp.name) + N';' AS drop_command
FROM sys.database_principals AS dp
WHERE dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys', 'public')
  AND dp.type <> 'R'
  AND dp.is_fixed_role = 0
ORDER BY dp.name;
*/


/*******************************************************************************
   SECTION 7: DATABASE LIFECYCLE OPERATIONS

   *** EXTREME CAUTION REQUIRED ***

   These queries generate commands that cause service disruption or remove
   databases from the instance. Review every generated command, maintain verified
   backups, and execute only during an approved maintenance window.
*******************************************************************************/

-----------------------------------------------------------------------
-- 7.1 GENERATE OFFLINE COMMANDS FOR ALL USER DATABASES
--     *** TAKES EVERY ONLINE USER DATABASE OFFLINE ***
-----------------------------------------------------------------------
/*
SELECT N'USE [master];' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET OFFLINE WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) AS offline_command
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name <> N'distribution'
ORDER BY d.name;
*/

-----------------------------------------------------------------------
-- 7.2 GENERATE DETACH COMMANDS FOR ALL USER DATABASES
--     *** REMOVES EVERY USER DATABASE FROM THE INSTANCE ***
-----------------------------------------------------------------------
/*
SELECT N'USE [master];' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
       N'EXEC master.dbo.sp_detach_db @dbname = N''' +
       REPLACE(d.name, N'''', N'''''') + N''';' + CHAR(13) + CHAR(10) AS detach_command
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name <> N'distribution'
ORDER BY d.name;
*/


/*******************************************************************************
   END OF FILE

   Renamed and reorganized from:
   - general-queries-for-troubleshooting.sql

   Merged into Section 3 from:
   - Causes for SQL Server Service Startup Failure.txt

   Last reorganized: July 25, 2026
*******************************************************************************/
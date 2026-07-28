/*******************************************************************************
 * SQL SERVER ADVANCED ADMINISTRATION & RECOVERY
 *
 * Purpose: Incident-response procedures for a SQL Server instance that is
 *          failing, unreachable, or misbehaving — error-log diagnostics,
 *          instance configuration, service startup failure triage, and
 *          emergency recovery.
 *
 * Sections:
 *   1. ERROR LOG DIAGNOSTICS
 *   2. INSTANCE CONFIGURATION & TRACE FLAGS
 *   3. SERVICE STARTUP FAILURE: CAUSES & DIAGNOSTICS
 *   4. EMERGENCY RECOVERY PROCEDURES
 *
 * Safety:  Section 1, the trace-flag query in Section 2, and the diagnostic
 *          queries in Section 3 are read-only. All configuration and recovery
 *          operations are commented out by default and clearly marked.
 *
 * Note:    Review placeholders and generated commands before execution. Test
 *          changes outside production and maintain verified backups.
 *
 * Related: other scripts/00-triage.sql          run this first during an incident
 *          database-integrity-checks.sql        DBCC, corruption detection & repair
 *          backups-and-restores.sql             restore paths and backup validation
 *          dangerous-admin-utilities.sql        xp_cmdshell, bulk DROP, offline/detach
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
    log_date DATETIME NULL,          -- sp_enumerrorlogs returns DATETIME; keep the time component
    log_size BIGINT NULL
);

DROP TABLE IF EXISTS #sp_readerrorlog_output;

-- Column types must match sp_readerrorlog's output. Text is NVARCHAR(MAX):
-- a narrower type raises "String or binary data would be truncated" and
-- aborts the sweep on the first long log entry.
CREATE TABLE #sp_readerrorlog_output
(
    LogDate DATETIME NULL,
    ProcessInfo NVARCHAR(100) NULL,
    Text NVARCHAR(MAX) NULL
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
   Engine) or SQL Server Agent service from starting, followed by the read-only
   diagnostic queries that are specific to startup failure. Use this section as
   a first pass when an instance is down or repeatedly recycling.

   Most causes in 3.1 are diagnosed from outside SQL Server (Event Viewer,
   Configuration Manager, the OS) because a service that will not start cannot
   be queried. General instance-health checks that need a working connection
   live in other scripts/00-triage.sql - see 3.5.
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
-- 3.3 CHECK TEMPDB FILE LOCATIONS AND STATE
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
-- 3.4 SEARCH THE ERROR LOG FOR COMMON STARTUP FAILURE SIGNATURES
--      Pair with Section 1.2 to sweep every archived log for these terms
--      READ-ONLY
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'recovery is', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'suspect', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'tempdb', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'17204', NULL, NULL, NULL, N'desc';
-- EXEC master.dbo.xp_readerrorlog 0, 1, N'3417', NULL, NULL, NULL, N'desc';
-- GO

-----------------------------------------------------------------------
-- 3.5 GENERAL INSTANCE HEALTH CHECKS — SEE other scripts/00-triage.sql
--     The checks below are not startup-specific, so they are maintained
--     in the triage script to keep a single copy. Run 00-triage.sql once
--     the instance is reachable; every item here is relevant to a
--     startup or availability investigation.
--
--       Service state, startup type,
--       service account, last startup ... 00-triage.sql  section 1
--       Database state (SUSPECT,
--       RECOVERY_PENDING, RESTORING) .... 00-triage.sql  section 2
--       THREADPOOL exhaustion ........... 00-triage.sql  section 5
--       Memory state and min/max memory   00-triage.sql  sections 1 and 7
--       Volume free space ............... 00-triage.sql  section 9
--       WSFC / AG cluster health ........ 00-triage.sql  section 11
--
--     Why each matters here: a Disabled or Manual start mode explains a
--     service that never came up; a full volume (OS error 112) can stop
--     recovery and mark a database SUSPECT; memory exhaustion can prevent
--     the buffer pool being allocated at startup; and THREADPOOL
--     exhaustion makes a running instance refuse new connections — which
--     is easily mistaken for the service being down.
--
--     See also: disk-space-and-file-management.sql for volume and file
--     growth detail.
-----------------------------------------------------------------------


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
-- 4.2 DATABASE-LEVEL CORRUPTION AND REPAIR
--     Emergency mode, REPAIR_ALLOW_DATA_LOSS, page-level restore, and
--     the FILESTREAM RECOVERY_PENDING procedure are maintained in
--     database-integrity-checks.sql, Section 3, alongside the CHECKDB
--     commands that detect the damage in the first place.
-----------------------------------------------------------------------


/*******************************************************************************
   END OF FILE

   Renamed and reorganized from:
   - general-queries-for-troubleshooting.sql

   Merged into Section 3 from:
   - Causes for SQL Server Service Startup Failure.txt

   Split out to dangerous-admin-utilities.sql (July 28, 2026):
   - former Section 5: Operating system commands (xp_cmdshell)
   - former Section 6: Database object & user removal
   - former Section 7: Database lifecycle operations (offline / detach)

   Moved to database-integrity-checks.sql Section 3 (July 28, 2026):
   - former Section 4.2: FILESTREAM RECOVERY_PENDING repair

   Moved to other scripts/00-triage.sql (July 28, 2026):
   - former Section 3.5: THREADPOOL exhaustion  -> triage section 5
   - former Section 3.6: memory state / config  -> triage sections 1 and 7
   - former Section 3.7: volume free space      -> triage section 9
   - former Section 3.3: database state         -> triage section 2 (superset)
   - former Section 3.5: WSFC / cluster health  -> triage section 11
   - former Section 3.6: service state          -> triage section 1

   Last reorganized: July 28, 2026
*******************************************************************************/
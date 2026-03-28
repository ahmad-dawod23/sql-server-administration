/*******************************************************************************
 * SQL SERVER ADMINISTRATION & CONFIGURATION GUIDE
 * 
 * Purpose: Comprehensive collection of SQL Server administration queries
 *          covering configuration, monitoring, diagnostics, and troubleshooting.
 * 
 * Sections:
 *   1. ERROR LOGS & DIAGNOSTICS
 *   2. TROUBLESHOOTING & RECOVERY
 *   3. SYSTEM COMMANDS (xp_cmdshell)
 *   4. DANGEROUS OPERATIONS (CAUTION REQUIRED)
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
   SECTION 3: SYSTEM COMMANDS (xp_cmdshell)
   
   WARNING: xp_cmdshell must be enabled and should only be used by authorized
            administrators. These commands execute with SQL Server service account
            privileges. Enable only when needed and disable immediately after use.
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 ENABLE xp_cmdshell
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
-- 3.2 DISABLE xp_cmdshell
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
-- 3.3 EXECUTE DIRECTORY LISTING
--     Example of OS command execution
-----------------------------------------------------------------------
-- EXEC xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 3.4 MAP NETWORK SHARE
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
   SECTION 4: DANGEROUS OPERATIONS (CAUTION REQUIRED)
   
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
-- 4.1 GENERATE DROP STATEMENTS FOR ALL USER FUNCTIONS
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
-- 4.2 GENERATE DROP STATEMENTS FOR ALL USER STORED PROCEDURES
--     WARNING: This will DELETE all user-defined stored procedures!
-----------------------------------------------------------------------
/*
SELECT 'DROP PROCEDURE [' + SCHEMA_NAME(p.schema_id) + '].[' + p.NAME + '];'
FROM sys.procedures p
WHERE is_ms_shipped = 0
ORDER BY SCHEMA_NAME(p.schema_id), p.NAME;
*/

-----------------------------------------------------------------------
-- 4.3 ALTERNATIVE: DROP FUNCTIONS (DIFFERENT METHOD)
-----------------------------------------------------------------------
/*
SELECT 'DROP FUNCTION [' + SCHEMA_NAME(o.schema_id) + '].[' + o.NAME + '];'
FROM sys.objects o 
WHERE type IN ('FN', 'IF', 'TF')  -- Scalar, Inline, Table-Valued
  AND is_ms_shipped = 0
ORDER BY SCHEMA_NAME(o.schema_id), o.NAME;
*/

-----------------------------------------------------------------------
-- 4.4 GENERATE OFFLINE COMMANDS FOR ALL USER DATABASES
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
-- 4.5 GENERATE DETACH COMMANDS FOR ALL USER DATABASES
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
-- 4.6 DROP ALL NON-SYSTEM DATABASE USERS
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


-----------------------------------------------------------------------
-- 5.3 TRACE FLAGS CURRENTLY ENABLED
--     Monitor active trace flags affecting server behavior
-----------------------------------------------------------------------
DBCC TRACESTATUS(-1);

-----------------------------------------------------------------------
-- 5.4 ENABLE ADVANCED OPTIONS
--     Required before changing advanced configuration options
--     *** MODIFIES SYSTEM SETTINGS ***
-----------------------------------------------------------------------
-- EXEC sp_configure 'show advanced option', '1';
-- GO
-- RECONFIGURE;
-- GO

-----------------------------------------------------------------------
-- 5.5 ADJUST MEMORY ALLOCATION AND MAXDOP
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

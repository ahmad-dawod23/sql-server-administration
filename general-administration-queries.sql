/*******************************************************************************
   GENERAL ADMINISTRATION QUERIES
   
   Purpose: Miscellaneous administration queries for SQL Server that don't
            fit into specialized categories.
            
   Sections:
   1. Error Log & Diagnostics
   2. SQL Managed Instance (SQL MI) Specific Commands
   3. Query Store Configuration
   4. Troubleshooting & Recovery
   5. System Commands (xp_cmdshell)
   
   Note: For specialized topics (backups, security, TDE, performance, etc.),
         see the dedicated script files in the parent directory.
*******************************************************************************/

USE MASTER;
GO

/*******************************************************************************
   SECTION 1: ERROR LOG & DIAGNOSTICS
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 Search Error Logs
-----------------------------------------------------------------------
EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';
GO


-- Search the SQL Server error log files for a nominated string
-- This script enumerates all of the available SQL Server error log files on an instance, and then searches each of them for a nominated string, returning a single result set.

SET NOCOUNT ON;

DECLARE @log_number INT,
        @search_string VARCHAR(255) = '<search_string>';

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

-----------------------------------------------------------------------
-- 1.2 Store Error Log Details (SQL MI Workaround)
--      Workaround for SQL MI not persisting error logs
-----------------------------------------------------------------------
-- Create storage table
CREATE TABLE ErrorLogDetails
(
    Logdate DATETIME,
    ProcessInfo VARCHAR(20),
    Text VARCHAR(MAX)
);
GO

-- Create stored procedure to capture and store error logs
CREATE PROCEDURE usp_StoreErrorlogdetails
AS
SET NOCOUNT ON;

-- Create temp tables
CREATE TABLE #total_logs
(
    log_number INT,
    log_date DATE,
    log_size INT
);

CREATE TABLE #TempErrorLogDetails
(
    Logdate DATETIME,
    ProcessInfo VARCHAR(20),
    Text VARCHAR(MAX)
);

-- Get the max error log number
INSERT #total_logs
(
    log_number,
    log_date,
    log_size
)
EXEC ('EXEC sys.sp_enumerrorlogs;');

DECLARE @lastlognumber INT,
        @currentlog INT,
        @sql NVARCHAR(MAX);

SET @currentlog = 0;

SELECT @lastlognumber = MAX(log_number)
FROM #total_logs;

WHILE @currentlog <= @lastlognumber
BEGIN
    SET @sql = 'master.dbo.sp_readerrorlog ' + TRIM(CAST(@currentlog AS CHAR(2)));

    INSERT INTO #TempErrorLogDetails
    (
        Logdate,
        ProcessInfo,
        Text
    )
    EXEC sp_executesql @sql;

    SET @currentlog = @currentlog + 1;
END;

-- Insert into table (avoid duplicates)
INSERT INTO MainatenanceDB.dbo.ErrorLogDetails
(
    logdate,
    processinfo,
    Text
)
SELECT A.Logdate,
       A.ProcessInfo,
       A.Text
FROM #TempErrorLogDetails A
    LEFT JOIN MainatenanceDB.dbo.ErrorLogDetails B
        ON A.Logdate = B.LogDate
WHERE B.logdate IS NULL;

-- Delete old data more than 30 days
DELETE FROM MainatenanceDB.dbo.ErrorLogDetails
WHERE logdate <= GETDATE() - 30;
GO




/*******************************************************************************
   SECTION 2: SQL MANAGED INSTANCE (SQL MI) SPECIFIC COMMANDS
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 Check SQL MI Operations Status
-----------------------------------------------------------------------
-- View current and recent operations on the managed instance
SELECT *
FROM sys.dm_operation_status
ORDER BY start_time DESC;
GO




/*******************************************************************************
   SECTION 3: QUERY STORE CONFIGURATION
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 Enable Query Store with Recommended Settings
--      Reference: https://www.sqlskills.com/blogs/erin/query-store-settings/
-----------------------------------------------------------------------
-- For SQL Server 2016 & 2017
USE [master];
GO

-- Enable Query Store
ALTER DATABASE [ChicagoBulls] SET QUERY_STORE = ON;
GO

-- Configure Query Store settings
ALTER DATABASE [ChicagoBulls]
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




/*******************************************************************************
   SECTION 4: TROUBLESHOOTING & RECOVERY
*******************************************************************************/

-----------------------------------------------------------------------
-- 4.1 Emergency SA Password Recovery
--      Use when SQL Server instance is inaccessible and no one remembers
--      the sa password. Requires local Administrator access.
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
-- 4.2 Emergency Repair for FileStream Recovery Pending
--      Fix databases stuck in Recovery Pending after Windows Update
--      Part of the SQL Server DBA Toolbox at 
--      https://github.com/DavidSchanzer/Sql-Server-DBA-Toolbox
-----------------------------------------------------------------------
-- This script avoids having to perform a database restore in the occasional 
-- circumstance where Windows patching causes a database that uses FileStream 
-- into the Recovery Pending state.
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




/*******************************************************************************
   SECTION 5: SYSTEM COMMANDS (xp_cmdshell)
   
   Warning: xp_cmdshell must be enabled and should only be used by authorized
            administrators. These commands execute with SQL Server service account
            privileges.
*******************************************************************************/

/*******************************************************************************
   SECTION 5: SYSTEM COMMANDS (xp_cmdshell)
   
   Warning: xp_cmdshell must be enabled and should only be used by authorized
            administrators. These commands execute with SQL Server service account
            privileges.
*******************************************************************************/

-----------------------------------------------------------------------
-- 5.1 Enable xp_cmdshell (if needed)
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
-- 5.2 Execute Directory Listing
-----------------------------------------------------------------------
-- EXEC xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 5.3 Map Network Share
--      Map a network drive for backup/restore operations
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
   END OF FILE
*******************************************************************************/
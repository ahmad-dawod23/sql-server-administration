-----------------------------------------------------------------------
-- TEMPDB PERFORMANCE & SPACE ANALYSIS
-- Purpose : Identify sessions consuming tempdb space, check file
--           configuration, version store usage, and contention.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. TEMPDB FILE CONFIGURATION & SIZING
-----------------------------------------------------------------------

-- 1.1 TempDB file size and growth parameters
SELECT
    name AS FileName, 
    size*1.0/128 AS FileSizeinMB,
    CASE max_size 
        WHEN 0 THEN 'Autogrowth is off.'
        WHEN -1 THEN 'Autogrowth is on.'
        ELSE 'Log file will grow to a maximum size of 2 TB.'
    END AS MaxSizeStatus,
    growth AS GrowthValue,
    CASE
        WHEN growth = 0 THEN 'Size is fixed and will not grow.'
        WHEN growth > 0 AND is_percent_growth = 0 
            THEN 'Growth value is in 8-KB pages.'
        ELSE 'Growth value is a percentage.'
    END AS GrowthIncrement
FROM tempdb.sys.database_files;
GO

-----------------------------------------------------------------------
-- 1.2 TempDB settings check with disk space analysis
--     Note: Requires xp_cmdshell to be enabled
-----------------------------------------------------------------------
DECLARE @max_size VARCHAR(max) 
SELECT @max_size = COALESCE(CONVERT(NVARCHAR(100),@max_size) + '  ', '') + CONVERT(NVARCHAR(100),(max_size*8)/1024)
FROM sys.master_files WHERE database_id = 2 AND type = 0 ORDER BY file_id;

DECLARE @size VARCHAR(max) 
SELECT @size = COALESCE(CONVERT(NVARCHAR(100),@size) + '  ', '') + CONVERT(NVARCHAR(100),(size*8)/1024)
FROM sys.master_files WHERE database_id = 2 AND type = 0 ORDER BY file_id;

DECLARE @growth VARCHAR(max) 
SELECT @growth = COALESCE(CONVERT(NVARCHAR(100),@growth) + '  ', '') + CASE WHEN is_percent_growth = 1 THEN '%' ELSE CONVERT(NVARCHAR(100),(growth*8)/1024) END
FROM sys.master_files WHERE database_id = 2 AND type = 0 ORDER BY file_id;

DECLARE @is_percent_growth VARCHAR(max) 
SELECT @is_percent_growth = COALESCE(CONVERT(NVARCHAR(100),@is_percent_growth) + '  ', '') + CONVERT(NVARCHAR(100),is_percent_growth)
FROM sys.master_files WHERE database_id = 2 AND type = 0 ORDER BY file_id;

DECLARE @LUN SYSNAME
SET @LUN = (SELECT SUBSTRING(physical_name, 1, CHARINDEX('\', physical_name, 4))
FROM sys.master_files WHERE database_id = 2 AND file_id = 1);

DECLARE @log_growth VARCHAR(100)
SELECT @log_growth = CASE WHEN is_percent_growth = 1 THEN '%' ELSE CONVERT(NVARCHAR(100),(growth*8)/1024) END
FROM sys.master_files WHERE database_id = 2 AND type = 1;

DECLARE @is_log_percent_growth BIT
SELECT @is_log_percent_growth = is_percent_growth
FROM sys.master_files WHERE database_id = 2 AND type = 1;

DECLARE @dedicated BIT
SET @dedicated = (SELECT CASE WHEN (@LUN LIKE '%tempdb%') THEN 1 ELSE 0 END);

DECLARE @cmd SYSNAME
SET @cmd = 'fsutil volume diskfree ' + @LUN + ' |find "Total # of bytes"'
DECLARE @Output TABLE (Output NVARCHAR(max))
INSERT INTO @Output
EXEC xp_cmdshell @cmd;

SELECT
    @LUN AS LUN,
    GB,
    @dedicated AS Dedicated,
    CASE WHEN @dedicated = 1 THEN
        CAST(FLOOR((((GB * 1024) * .8) / 8)) AS NVARCHAR(30))
    ELSE
        CAST(FLOOR(((((GB - 10) * 1024) * .7) / 8)) AS NVARCHAR(30)) 
    END AS [Standard Size MB],
    @size AS [Actual Size MB],
    @max_size AS [Max Size MB], 
    @growth AS [Growth MB],
    @is_percent_growth AS [Is Percent Growth],
    @log_growth AS [Log Growth MB],
    @is_log_percent_growth AS [Is Log Percent Growth]
FROM
(
    SELECT @LUN AS LUN, CONVERT(BIGINT,REPLACE([Output], 'Total # of bytes             : ', '')) / 1073698000 AS GB
    FROM @Output 
    WHERE [Output] IS NOT NULL
) AS x;
GO

-----------------------------------------------------------------------
-- 2. TEMPDB SPACE USAGE BY SESSIONS
-----------------------------------------------------------------------

-- 2.1 Sessions with high tempdb usage (summary with session details)
SELECT 
    tsu.session_id,
    SUM(tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) AS TotalAllocatedPages,
    SUM(tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count) AS TotalDeallocatedPages,
    SUM((tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) -
        (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count)) AS NetTempDBPages,
    s.login_name,
    s.host_name,
    s.program_name
FROM sys.dm_db_session_space_usage tsu
JOIN sys.dm_exec_sessions s ON tsu.session_id = s.session_id
WHERE tsu.session_id > 50 -- Exclude system sessions
GROUP BY tsu.session_id, s.login_name, s.host_name, s.program_name
ORDER BY NetTempDBPages DESC;
GO

-----------------------------------------------------------------------
-- 2.2 Top 10 sessions consuming tempdb space (task-level)
SELECT TOP(10)
    session_id,
    SUM(user_objects_alloc_page_count + user_objects_dealloc_page_count + 
        internal_objects_alloc_page_count + internal_objects_dealloc_page_count)/128 AS [Reserved (MB)]
FROM sys.dm_db_task_space_usage
GROUP BY session_id
ORDER BY SUM(user_objects_alloc_page_count + user_objects_dealloc_page_count + 
             internal_objects_alloc_page_count + internal_objects_dealloc_page_count)/128 DESC;
GO

-----------------------------------------------------------------------
-- 2.3 Detailed session space usage breakdown
SELECT
    s.session_id AS [Session ID],
    DB_NAME(s.database_id) AS [Database Name],
    s.host_name AS [System Name],
    s.program_name AS [Program Name],
    s.login_name AS [User Name],
    s.status,
    s.cpu_time AS [CPU Time (ms)],
    s.total_scheduled_time AS [Total Scheduled Time (ms)],
    s.total_elapsed_time AS [Elapsed Time (ms)],
    (s.memory_usage * 8) AS [Memory Usage (KB)],
    (tsu.user_objects_alloc_page_count * 8) AS [Space Allocated for User Objects (KB)],
    (tsu.user_objects_dealloc_page_count * 8) AS [Space Deallocated for User Objects (KB)],
    (tsu.internal_objects_alloc_page_count * 8) AS [Space Allocated for Internal Objects (KB)],
    (tsu.internal_objects_dealloc_page_count * 8) AS [Space Deallocated for Internal Objects (KB)],
    CASE s.is_user_process
        WHEN 1 THEN 'User Session'
        WHEN 0 THEN 'System Session'
    END AS [Session Type], 
    s.row_count AS [Row Count]
FROM sys.dm_db_session_space_usage tsu
JOIN sys.dm_exec_sessions s ON tsu.session_id = s.session_id
ORDER BY (tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) DESC;
GO

-----------------------------------------------------------------------
-- 2.4 Session and task space usage with query text (for active queries)
--     Shows sessions using more than 1 MB of tempdb space
WITH TempdbCTE AS
(
    SELECT 
        session_id, 
        SUM(user_objects_alloc_page_count) AS task_user_objects_alloc_page_count,
        SUM(user_objects_dealloc_page_count) AS task_user_objects_dealloc_page_count 
    FROM sys.dm_db_task_space_usage 
    GROUP BY session_id
)
SELECT 
    R1.session_id,
    (R1.user_objects_alloc_page_count + R2.task_user_objects_alloc_page_count)/128 AS session_user_objects_alloc_MB,
    (R1.user_objects_dealloc_page_count + R2.task_user_objects_dealloc_page_count)/128 AS session_user_objects_dealloc_MB, 
    st.text AS QueryText
FROM sys.dm_db_session_space_usage AS R1 
INNER JOIN TempdbCTE AS R2 ON R1.session_id = R2.session_id
JOIN sys.dm_exec_requests er ON er.session_id = R1.session_id
CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) AS st
WHERE R2.task_user_objects_alloc_page_count > 127  -- Minimum 1 MB used space
ORDER BY session_user_objects_alloc_MB DESC;
GO

-----------------------------------------------------------------------
-- 3. TEMPDB CONTENTION ANALYSIS
-----------------------------------------------------------------------

-- 3.1 Active requests with tempdb waits
--     Note: When wait_resource has '2:x:y', it's tempdb (database_id = 2)
SELECT 
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    r.last_wait_type,
    r.total_elapsed_time AS total_elapsed_time_in_milliseconds,
    r.status,
    r.command,
    r.cpu_time,
    r.logical_reads,
    r.reads,
    r.writes,
    s.host_name,
    s.program_name,
    s.login_name,
    DB_NAME(r.database_id) AS db_name,
    SUBSTRING(t.text, statement_start_offset/2, 
        (CASE WHEN statement_end_offset = -1 
            THEN LEN(CONVERT(NVARCHAR(max), t.text)) * 2 
            ELSE statement_end_offset 
        END - statement_start_offset)/2) AS sql_statement_executing_now,
    t.text AS full_query_text,
    OBJECT_NAME(p.objectid, p.dbid) AS object_name
FROM sys.dm_exec_requests r 
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id 
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t 
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) p 
WHERE (r.wait_type != 'BROKER_RECEIVE_WAITFOR' OR r.wait_type IS NULL)
ORDER BY r.total_elapsed_time DESC;
GO

-----------------------------------------------------------------------
-- 3.2 TempDB contention on system pages (PFS, GAM, SGAM)
--     Identifies contention on allocation pages which can indicate 
--     insufficient tempdb data files
SELECT 
    session_id, 
    wait_type, 
    wait_duration_ms, 
    blocking_session_id, 
    resource_description,
    ResourceType = CASE 
        WHEN CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 1 % 8088 = 0 THEN 'Is PFS Page'
        WHEN CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 2 % 511232 = 0 THEN 'Is GAM Page'
        WHEN CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 3 % 511232 = 0 THEN 'Is SGAM Page'
        ELSE 'Is Not PFS, GAM, or SGAM page' 
    END
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'PAGE%LATCH_%'
  AND resource_description LIKE '2:%'
ORDER BY wait_duration_ms DESC;
GO

-----------------------------------------------------------------------
-- 4. TEMPDB VERSION STORE USAGE
-----------------------------------------------------------------------

-- 4.1 Version store space usage by database
--     Useful for identifying databases with long-running transactions
--     or snapshot isolation that consume tempdb version store
SELECT 
    DB_NAME(database_id) AS [Database Name],
    reserved_page_count AS [Version Store Reserved Page Count], 
    reserved_space_kb/1024 AS [Version Store Reserved Space (MB)] 
FROM sys.dm_tran_version_store_space_usage WITH (NOLOCK) 
ORDER BY reserved_space_kb/1024 DESC 
OPTION (RECOMPILE);

-- Reference: sys.dm_tran_version_store_space_usage (Transact-SQL)
-- https://bit.ly/2vh3Bmk
GO













-----------------------------------------------------------------------
-- TEMPDB PERFORMANCE & SPACE ANALYSIS
-- Purpose : Identify sessions consuming tempdb space, check file
--           configuration, version store usage, and contention.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. SESSIONS WITH HIGH TEMPDB USAGE
--    Identifies sessions and queries consuming the most tempdb space.
-----------------------------------------------------------------------

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
--ORDER BY NetTempDBPages DESC;



/**********************************************************************************************/
-- most use of tempdb - five executing tasks

SELECT top 5 * FROM sys.dm_db_session_space_usage
ORDER BY (user_objects_alloc_page_count + internal_objects_alloc_page_count) DESC

/**********************************************************************************************/
-- Top 10 Sessions consuming tempdb space

SELECT TOP(10)
       session_id,
       SUM(user_objects_alloc_page_count+user_objects_dealloc_page_count+internal_objects_alloc_page_count+internal_objects_dealloc_page_count)/128 AS 'Reserved (MB)'
FROM
       sys.dm_db_task_space_usage
GROUP BY
       session_id
ORDER BY
       SUM(user_objects_alloc_page_count+user_objects_dealloc_page_count+internal_objects_alloc_page_count+internal_objects_dealloc_page_count)/128 DESC

/**********************************************************************************************/
-- Breakdown of sessions

SELECT
       s.session_id,  
       s.host_name,
       s.host_process_id,
       s.program_name,
       s.login_name,
       s.cpu_time,
       s.memory_usage,
       s.reads,
       s.writes,
       s.transaction_isolation_level
FROM
       sys.dm_exec_sessions s
WHERE
       s.is_user_process = 1
-- Optional 'where' criteria to limit by host
--AND  s.host_name in ('ServerName1', 'ServerName2')
ORDER BY
       s.session_id

/**********************************************************************************************/
-- size and file growth parameters of the tempdb data or log files

SELECT
    name AS FileName, 
    size*1.0/128 AS FileSizeinMB,
    CASE max_size 
        WHEN 0 THEN 'Autogrowth is off.'
        WHEN -1 THEN 'Autogrowth is on.'
        ELSE 'Log file will grow to a maximum size of 2 TB.'
    END,
    growth AS 'GrowthValue',
    'GrowthIncrement' = 
        CASE
            WHEN growth = 0 THEN 'Size is fixed and will not grow.'
            WHEN growth > 0 AND is_percent_growth = 0 
                THEN 'Growth value is in 8-KB pages.'
            ELSE 'Growth value is a percentage.'
        END
FROM tempdb.sys.database_files;
GO

/**********************************************************************************************/
-- Pages allocated and deallocated by each session 

SELECT
	sys.dm_exec_sessions.session_id           AS [SESSION ID],
	DB_NAME(database_id)                      AS [DATABASE Name],
	HOST_NAME                                 AS [System Name],
	program_name                              AS [Program Name],
	login_name                                AS [USER Name],
	status,
	cpu_time                                  AS [CPU TIME (in milisec)],
	total_scheduled_time                      AS [Total Scheduled TIME (in milisec)],
	total_elapsed_time                        AS [Elapsed TIME (in milisec)],
	(memory_usage * 8)                        AS [Memory USAGE (in KB)],
	(user_objects_alloc_page_count * 8)       AS [SPACE Allocated FOR USER Objects (in KB)],
	(user_objects_dealloc_page_count * 8)     AS [SPACE Deallocated FOR USER Objects (in KB)],
	(internal_objects_alloc_page_count * 8)   AS [SPACE Allocated FOR Internal Objects (in KB)],
	(internal_objects_dealloc_page_count * 8) AS [SPACE Deallocated FOR Internal Objects (in KB)],
	CASE is_user_process
		WHEN 1      THEN 'user session'
		WHEN 0      THEN 'system session'
	END                                       AS [SESSION Type], 
	row_count                                 AS [ROW COUNT]
FROM 
	sys.dm_db_session_space_usage
JOIN
	sys.dm_exec_sessions
ON 
	sys.dm_db_session_space_usage.session_id = sys.dm_exec_sessions.session_id
ORDER BY 
	(user_objects_alloc_page_count + internal_objects_alloc_page_count) DESC

/**********************************************************************************************/
-- My colleague's version:

WITH TempdbCTE
AS
  (SELECT session_id, 
      SUM(user_objects_alloc_page_count) AS task_user_objects_alloc_page_count,
      SUM(user_objects_dealloc_page_count) AS task_user_objects_dealloc_page_count 
    FROM sys.dm_db_task_space_usage 
    GROUP BY session_id)
SELECT R1.session_id,
        (R1.user_objects_alloc_page_count
        + R2.task_user_objects_alloc_page_count)/128 AS session_user_objects_alloc_MB,
        (R1.user_objects_dealloc_page_count 
        + R2.task_user_objects_dealloc_page_count)/128 AS session_user_objects_dealloc_MB, 
             st.text 
    FROM sys.dm_db_session_space_usage AS R1 
    INNER JOIN TempdbCTE AS R2 ON R1.session_id = R2.session_id
       JOIN sys.dm_exec_requests er on er.session_id = r1.session_id
       CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) as st
       where R2.task_user_objects_alloc_page_count > 127  -- where min 1 MB used space
GO


/**********************************************************************************************/
/*
	CMS-friendly script to check TempDB settings

	Version: 1.0
	Modified: 5/29/2013
		
	script requires xp_cmdshell to be enabled 
*/

DECLARE @max_size VARCHAR(max) 
SELECT @max_size = COALESCE(CONVERT(nvarchar(100),@max_size) + '  ', '') + CONVERT(nvarchar(100),(max_size*8)/1024)
from sys.master_files where database_id = 2 and type = 0 order by file_id

DECLARE @size VARCHAR(max) 
SELECT @size = COALESCE(CONVERT(nvarchar(100),@size) + '  ', '') + CONVERT(nvarchar(100),(size*8)/1024)
from sys.master_files where database_id = 2 and type = 0 order by file_id

DECLARE @growth VARCHAR(max) 
SELECT @growth = COALESCE(CONVERT(nvarchar(100),@growth) + '  ', '') + CASE WHEN is_percent_growth = 1 THEN '%' ELSE CONVERT(nvarchar(100),(growth*8)/1024) END
from sys.master_files where database_id = 2 and type = 0 order by file_id

DECLARE @is_percent_growth VARCHAR(max) 
SELECT @is_percent_growth = COALESCE(CONVERT(nvarchar(100),@is_percent_growth) + '  ', '') + CONVERT(nvarchar(100),is_percent_growth)
from sys.master_files where database_id = 2 and type = 0 order by file_id

DECLARE @LUN sysname
SET @LUN = (select SUBSTRING(physical_name, 1, CHARINDEX('\', physical_name, 4))
from sys.master_files where database_id = 2 and file_id = 1)

DECLARE @log_growth varchar(100)
SELECT @log_growth = CASE WHEN is_percent_growth = 1 THEN '%' ELSE CONVERT(nvarchar(100),(growth*8)/1024) END
from sys.master_files where database_id = 2 and type = 1

DECLARE @is_log_percent_growth bit
SELECT @is_log_percent_growth = is_percent_growth
from sys.master_files where database_id = 2 and type = 1

DECLARE @dedicated bit
SET @dedicated = (SELECT CASE WHEN (@LUN like '%tempdb%') THEN 1 ELSE 0 END)

DECLARE @cmd sysname
SET @cmd = 'fsutil volume diskfree ' + @LUN + ' |find "Total # of bytes"'
DECLARE @Output TABLE
(
	Output nvarchar(max)
)
INSERT INTO @Output
EXEC xp_cmdshell @cmd

SELECT
	@LUN as 'LUN',
	GB,
	@dedicated as 'Dedicated',
		CASE WHEN @dedicated = 1 THEN
			CAST(FLOOR((((GB * 1024) * .8) / 8)) as NVARCHAR(30))
		ELSE
			CAST(FLOOR(((((GB - 10) * 1024) * .7) / 8)) as NVARCHAR(30)) 
		END as 'standard size MB', -- source: \\he-software\DBA\SQLAdmin\Build\MSSQL Installations\Installation Scripts\TempDB Separate Devs.sql
	@size as 'actual size MB',
	@max_size as 'max size MB', 
	@growth as 'growth MB',
	@is_percent_growth 'is percent growth',
	@log_growth as 'log growth MB',
	@is_log_percent_growth as 'is log percent growth'
FROM
(
	SELECT @LUN as 'LUN', CONVERT(bigint,REPLACE([Output], 'Total # of bytes             : ', '' )) / 1073698000 as 'GB'
	FROM @Output 
	WHERE [Output] IS NOT NULL
) as x

/**********************************************************************************************/
/* 
	TempDB contention check
	when the waits_resource field has the 2:: something value, its the tempdb
*/

select 
 r.total_elapsed_time as total_elapsed_time_in_milliseconds 
,r.wait_type 
,r.wait_time 
,r.wait_resource 
,r.last_wait_type 
,r.session_id 
,r.blocking_session_id 
,SUBSTRING(t.text,statement_start_offset/2,(CASE WHEN 
statement_end_offset = -1 then LEN(CONVERT(nvarchar(max), t.text)) * 2 ELSE 
statement_end_offset end -statement_start_offset)/2) 
as sql_statement_executing_now 
,t.text 
,r.status 
,r.command 
,r.logical_reads 
,r.cpu_time 
,r.reads 
,r.writes 
,s.host_name 
,s.program_name 
,s.login_name 
,s.status 
,s.memory_usage 
,db_name(r.database_id) as db_name 
,r.plan_handle 
,p.objectid 
,object_name(p.objectid,p.dbid) as object_name 
--,p.query_plan 
from sys.dm_exec_requests r 
join sys.dm_exec_sessions s 
on r.session_id = s.session_id 
cross apply sys.dm_exec_sql_text (r.sql_handle) t 
cross apply sys.dm_exec_query_plan(r.plan_handle) p 
WHERE 
      r.wait_type != 'BROKER_RECEIVE_WAITFOR' OR r.wait_type IS NULL --filter out service broker waits 
order by 
r.total_elapsed_time desc -- long running executions 
--r.logical_reads desc -- high reads i/o 
--r.cpu_time desc -- high cpu

/**********************************************************************************************/
/* 
	TempDB contention check - problematic pages	
*/

Select session_id, wait_type, wait_duration_ms, blocking_session_id, resource_description, 
ResourceType = Case 
            When Cast(Right(resource_description, Len(resource_description) - Charindex(':', resource_description, 3)) As Int) - 1 % 8088 = 0 Then 'Is PFS Page'
            When Cast(Right(resource_description, Len(resource_description) - Charindex(':', resource_description, 3)) As Int) - 2 % 511232 = 0 Then 'Is GAM Page'
            When Cast(Right(resource_description, Len(resource_description) - Charindex(':', resource_description, 3)) As Int) - 3 % 511232 = 0 Then 'Is SGAM Page'
            Else 'Is Not PFS, GAM, or SGAM page' 
            End
From sys.dm_os_waiting_tasks
Where wait_type Like 'PAGE%LATCH_%'
And resource_description Like '2:%'


DROP TABLE IF EXISTS #SQLErrorLog_AllLogs;

	CREATE TABLE #SQLErrorLog_AllLogs

	(LogDate DATETIME ,ProcessInfo NVARCHAR(12), LogText NVARCHAR(4000))







WHILE (@i < @logCount)

    BEGIN

        IF(@i in (SELECT [Archive #] FROM #ErrorLogFiles))

            BEGIN

                SET @sql = N'INSERT INTO #SQLErrorLog_AllLogs (LogDate, ProcessInfo, LogText)

                             EXEC master.sys.sp_readerrorlog ' + CAST(@i AS NVARCHAR(2)) + N';'

                EXEC master.sys.sp_executesql @sql;

            END

        SET @i += 1;

    END



-- Virtual Log Files (VLFs)

-- https://bit.ly/3TN6en1
















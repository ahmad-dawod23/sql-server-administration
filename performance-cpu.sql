-----------------------------------------------------------------------
-- CPU PERFORMANCE ANALYSIS
-- Purpose: Identify top CPU-consuming queries (active and cached),
--          CPU utilization trends, and scheduler pressure.
-- Safety: All queries are read-only.
-- Applies to: On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

-----------------------------------------------------------------------
-- SECTION 1: REAL-TIME ACTIVE CPU QUERIES
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 TOP 10 ACTIVE CPU QUERIES BY SESSION
--     Shows currently executing queries ordered by CPU time.
-----------------------------------------------------------------------
SELECT TOP 10
    req.session_id, 
    req.start_time, 
    req.cpu_time AS cpu_time_ms, 
    OBJECT_NAME(st.objectid, st.dbid) AS ObjectName,  
    SUBSTRING(
        REPLACE(REPLACE(
            SUBSTRING(st.text, (req.statement_start_offset/2) + 1,   
                ((CASE statement_end_offset
                    WHEN -1 THEN DATALENGTH(st.text)   
                    ELSE req.statement_end_offset 
                END - req.statement_start_offset)/2) + 1), 
            CHAR(10), ' '), 
        CHAR(13), ' '), 
    1, 512) AS statement_text   
FROM sys.dm_exec_requests AS req   
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st 
ORDER BY cpu_time DESC;
GO 

-----------------------------------------------------------------------
-- 1.2 TOP 10 ACTIVE CPU QUERIES AGGREGATED BY QUERY HASH
--     Aggregates CPU consumption for identical queries.
-----------------------------------------------------------------------
SELECT TOP 10 
    GETDATE() AS runtime,  
    query_stats.query_hash,    
    SUM(query_stats.cpu_time) AS Total_Request_Cpu_Time_Ms, 
    SUM(logical_reads) AS Total_Request_Logical_Reads, 
    MIN(start_time) AS Earliest_Request_start_Time, 
    COUNT(*) AS Number_Of_Requests, 
    SUBSTRING(
        REPLACE(REPLACE(MIN(query_stats.statement_text), CHAR(10), ' '), CHAR(13), ' '), 
    1, 256) AS Statement_Text   
FROM (
    SELECT 
        req.*,  
        SUBSTRING(st.text, (req.statement_start_offset/2) + 1, 
            ((CASE statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)   
                ELSE req.statement_end_offset 
            END - req.statement_start_offset)/2) + 1) AS statement_text   
    FROM sys.dm_exec_requests AS req   
        CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
) AS query_stats   
GROUP BY query_hash
ORDER BY Total_Request_Cpu_Time_Ms DESC;
GO 

-----------------------------------------------------------------------
-- 1.3 DETAILED CPU QUERY ANALYSIS WITH EXECUTION PLANS
--     Includes session details and actual/estimated execution plans.
-----------------------------------------------------------------------
SELECT 
    req.session_id, 
    req.status, 
    req.start_time, 
    req.cpu_time AS cpu_time_ms, 
    req.query_hash,
    req.logical_reads,
    req.dop,
    s.login_name,
    s.host_name,
    s.program_name,
    OBJECT_NAME(st.objectid, st.dbid) AS object_name,
    REPLACE(REPLACE(
        SUBSTRING(st.text, (req.statement_start_offset/2) + 1, 
            ((CASE req.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text) 
                ELSE req.statement_end_offset 
            END - req.statement_start_offset)/2) + 1), 
        CHAR(10), ' '), 
    CHAR(13), ' ') AS statement_text,
    qp.query_plan,
    qsx.query_plan AS query_plan_with_in_flight_statistics
FROM sys.dm_exec_requests AS req
    INNER JOIN sys.dm_exec_sessions AS s 
        ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
    OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) AS qp
    OUTER APPLY sys.dm_exec_query_statistics_xml(req.session_id) AS qsx
WHERE req.session_id <> @@SPID
ORDER BY req.cpu_time DESC;
GO

-----------------------------------------------------------------------
-- SECTION 2: HISTORICAL CPU QUERIES (QUERY STORE)
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 TOP 15 CPU CONSUMING QUERIES FROM QUERY STORE (RECENT)
--     Top 15 CPU consuming queries by query hash from last 2 hours.
--     Note: A query hash can have many query IDs if not parameterized properly.
-----------------------------------------------------------------------
WITH AggregatedCPU AS (
    SELECT 
        q.query_hash, 
        SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, 
        SUM(count_executions * avg_cpu_time / 1000.0) /SUM(count_executions) AS avg_cpu_millisec, 
        MAX(rs.max_cpu_time/1000.00) AS max_cpu_millisec, 
        MAX(max_logical_io_reads) max_logical_reads, 
        COUNT(DISTINCT p.plan_id) AS number_of_distinct_plans, 
        COUNT(DISTINCT p.query_id) AS number_of_distinct_query_ids, 
        SUM(CASE WHEN rs.execution_type_desc='Aborted' THEN count_executions ELSE 0 END) AS Aborted_Execution_Count, 
        SUM(CASE WHEN rs.execution_type_desc='Regular' THEN count_executions ELSE 0 END) AS Regular_Execution_Count, 
        SUM(CASE WHEN rs.execution_type_desc='Exception' THEN count_executions ELSE 0 END) AS Exception_Execution_Count, 
        SUM(count_executions) AS total_executions, 
        MIN(qt.query_sql_text) AS sampled_query_text 
    FROM sys.query_store_query_text AS qt 
        JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id 
        JOIN sys.query_store_plan AS p ON q.query_id = p.query_id 
        JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id 
        JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id 
    WHERE   
        rs.execution_type_desc IN ('Regular', 'Aborted', 'Exception') AND   
        rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())  
    GROUP BY q.query_hash 
), 
OrderedCPU AS ( 
    SELECT 
        query_hash, 
        total_cpu_millisec, 
        avg_cpu_millisec,
        max_cpu_millisec,  
        max_logical_reads, 
        number_of_distinct_plans, 
        number_of_distinct_query_ids,  
        total_executions, 
        Aborted_Execution_Count,
        Regular_Execution_Count, 
        Exception_Execution_Count, 
        sampled_query_text, 
        ROW_NUMBER() OVER (ORDER BY total_cpu_millisec DESC, query_hash ASC) AS RN 
    FROM AggregatedCPU 
) 
SELECT * 
FROM OrderedCPU OD  
WHERE OD.RN <= 15 
ORDER BY total_cpu_millisec DESC;
GO

-----------------------------------------------------------------------
-- SECTION 3: CPU HARDWARE & CONFIGURATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 GET SOCKET, PHYSICAL CORE AND LOGICAL CORE COUNT
--     Reads from SQL Server Error log.
--     Note: This query might take a few seconds depending on error log size.
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'detected', N'socket';
GO

-----------------------------------------------------------------------
-- 3.2 GET PROCESSOR DESCRIPTION FROM WINDOWS REGISTRY
--     Shows processor model and specifications (Windows only).
-----------------------------------------------------------------------
EXEC sys.xp_instance_regread 
    N'HKEY_LOCAL_MACHINE', 
    N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 
    N'ProcessorNameString';
GO

-----------------------------------------------------------------------
-- 3.3 SQL SERVER NUMA NODE INFORMATION
--     Shows NUMA configuration and memory distribution.
-----------------------------------------------------------------------
SELECT 
    osn.node_id, 
    osn.node_state_desc, 
    osn.memory_node_id, 
    osn.processor_group, 
    osn.cpu_count, 
    osn.online_scheduler_count, 
    osn.idle_scheduler_count, 
    osn.active_worker_count, 
    osmn.pages_kb/1024 AS [Committed_Memory_MB], 
    osmn.locked_page_allocations_kb/1024 AS [Locked_Physical_MB],
    CONVERT(DECIMAL(18,2), osmn.foreign_committed_kb/1024.0) AS [Foreign_Commited_MB],
    osmn.target_kb/1024 AS [Target_Memory_Goal_MB],
    osn.avg_load_balance, 
    osn.resource_monitor_state
FROM sys.dm_os_nodes AS osn WITH (NOLOCK)
    INNER JOIN sys.dm_os_memory_nodes AS osmn WITH (NOLOCK)
        ON osn.memory_node_id = osmn.memory_node_id
WHERE osn.node_state_desc <> N'ONLINE DAC' 
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 3.4 GET CPU VECTORIZATION LEVEL (SQL Server 2022+)
--     Shows CPU vectorization support for query processing.
-----------------------------------------------------------------------
IF EXISTS (SELECT * WHERE CONVERT(VARCHAR(2), SERVERPROPERTY('ProductMajorVersion')) = '16')
BEGIN		
    -- Get CPU Description from Registry (only works on Windows)
    DROP TABLE IF EXISTS #ProcessorDesc;
    CREATE TABLE #ProcessorDesc (
        RegValue NVARCHAR(50), 
        RegKey NVARCHAR(100)
    );

    INSERT INTO #ProcessorDesc (RegValue, RegKey)
    EXEC sys.xp_instance_regread 
        N'HKEY_LOCAL_MACHINE', 
        N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 
        N'ProcessorNameString';
    
    DECLARE @ProcessorDesc NVARCHAR(100) = (SELECT RegKey FROM #ProcessorDesc);

    -- Get CPU Vectorization Level from SQL Server Error Log
    DROP TABLE IF EXISTS #CPUVectorizationLevel;
    CREATE TABLE #CPUVectorizationLevel (
        LogDateTime DATETIME, 
        ProcessInfo NVARCHAR(12), 
        LogText NVARCHAR(200)
    );

    INSERT INTO #CPUVectorizationLevel (LogDateTime, ProcessInfo, LogText)
    EXEC sys.xp_readerrorlog 0, 1, N'CPU vectorization level';
    
    DECLARE @CPUVectorizationLevel NVARCHAR(200) = (SELECT LogText FROM #CPUVectorizationLevel);

    -- Get TF15097 Status
    DROP TABLE IF EXISTS #TraceFlagStatus;
    CREATE TABLE #TraceFlagStatus (
        TraceFlag SMALLINT, 
        TFStatus TINYINT, 
        TFGlobal TINYINT, 
        TFSession TINYINT
    );




    -- Display results
    SELECT 
        @ProcessorDesc AS ProcessorDescription,
        @CPUVectorizationLevel AS CPUVectorizationLevel;
    
    -- Cleanup
    DROP TABLE IF EXISTS #ProcessorDesc;
    DROP TABLE IF EXISTS #CPUVectorizationLevel;
    DROP TABLE IF EXISTS #TraceFlagStatus;
END
GO

-----------------------------------------------------------------------
-- SECTION 4: CPU SCHEDULER & TASK ANALYSIS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 GET AVERAGE TASK COUNTS (Run Multiple Times)
--     Shows scheduler pressure and CPU workload distribution.
--     Run multiple times to identify trends and spikes.
-----------------------------------------------------------------------
SELECT 
    AVG(current_tasks_count) AS [Avg_Task_Count], 
    AVG(work_queue_count) AS [Avg_Work_Queue_Count],
    AVG(runnable_tasks_count) AS [Avg_Runnable_Task_Count],
    AVG(pending_disk_io_count) AS [Avg_Pending_DiskIO_Count],
    GETDATE() AS [System_Time]
FROM sys.dm_os_schedulers WITH (NOLOCK)
WHERE scheduler_id < 255  -- Exclude hidden schedulers
OPTION (RECOMPILE);
GO
-----------------------------------------------------------------------
-- SECTION 5: SQL SERVER INSTANCE CPU UTILIZATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 SQL SERVER INSTANCE CPU UTILIZATION HISTORY
--     Shows SQL Server vs Other process CPU utilization over time.
--     Adjust @lastNmin to change time window.
-----------------------------------------------------------------------
DECLARE @ts BIGINT;
DECLARE @lastNmin TINYINT;
SET @lastNmin = 100;

SELECT @ts = (SELECT cpu_ticks / (cpu_ticks / ms_ticks) FROM sys.dm_os_sys_info); 

SELECT TOP(@lastNmin)
    SQLProcessUtilization AS [SQLServer_CPU_Utilization], 
    SystemIdle AS [System_Idle_Process], 
    100 - SystemIdle - SQLProcessUtilization AS [Other_Process_CPU_Utilization], 
    DATEADD(ms, -1 * (@ts - [timestamp]), GETDATE()) AS [Event_Time] 
FROM (
    SELECT 
        record.value('(./Record/@id)[1]', 'int') AS record_id, 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS [SystemIdle], 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS [SQLProcessUtilization], 
        [timestamp]      
    FROM (
        SELECT [timestamp], CONVERT(XML, record) AS [record]             
        FROM sys.dm_os_ring_buffers             
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
            AND record LIKE '%%'
    ) AS x 
) AS y 
ORDER BY record_id DESC;
GO

-----------------------------------------------------------------------
-- SECTION 6: DATABASE-LEVEL CPU ANALYSIS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 DATABASE CPU CONSUMPTION SNAPSHOT AND DELTA
--     Shows CPU consumption by database with delta analysis.
--     Takes two snapshots 10 seconds apart to show CPU rate.
-----------------------------------------------------------------------
-- First snapshot
IF OBJECT_ID('tempdb.dbo.#tbl', 'U') IS NOT NULL
    DROP TABLE #tbl;

WITH DB_CPU AS (
    SELECT 
        DatabaseID, 
        DB_Name(DatabaseID) AS [DatabaseName], 
        SUM(total_worker_time) AS [CPU_Time_Ms] 
    FROM sys.dm_exec_query_stats AS qs 
        CROSS APPLY (
            SELECT CONVERT(INT, value) AS [DatabaseID]  
            FROM sys.dm_exec_plan_attributes(qs.plan_handle)  
            WHERE attribute = N'dbid'
        ) AS epa 
    GROUP BY DatabaseID
) 
SELECT 
    GETDATE() AS reportedtime,
    ROW_NUMBER() OVER(ORDER BY [CPU_Time_Ms] DESC) AS [SNO], 
    DatabaseName AS [DBName], 
    [CPU_Time_Ms], 
    CAST([CPU_Time_Ms] * 1.0 / SUM([CPU_Time_Ms]) OVER() * 100.0 AS DECIMAL(5, 2)) AS [CPUPercent] 
INTO #tbl
FROM DB_CPU 
WHERE DatabaseID > 4  -- Exclude system databases 
    AND DatabaseID <> 32767  -- Exclude ResourceDB 
ORDER BY SNO 
OPTION(RECOMPILE); 

-- Wait 10 seconds
WAITFOR DELAY '00:00:10';

-- Second snapshot with delta calculation
WITH DB_CPU AS (
    SELECT 
        DatabaseID, 
        DB_Name(DatabaseID) AS [DatabaseName], 
        SUM(total_worker_time) AS [CPU_Time_Ms] 
    FROM sys.dm_exec_query_stats AS qs 
        CROSS APPLY (
            SELECT CONVERT(INT, value) AS [DatabaseID]  
            FROM sys.dm_exec_plan_attributes(qs.plan_handle)  
            WHERE attribute = N'dbid'
        ) AS epa 
    GROUP BY DatabaseID
) 
SELECT 
    a.DatabaseName AS [DBName], 
    CAST((a.[CPU_Time_Ms] - b.[CPU_Time_Ms]) * 1.0 / SUM((a.[CPU_Time_Ms] - b.[CPU_Time_Ms])) OVER() * 100.0 AS DECIMAL(5, 2)) AS [CPUPercent_Last10Sec] 
FROM DB_CPU a 
    INNER JOIN #tbl b ON a.[DatabaseName] = b.[DBName]
WHERE DatabaseID > 4  -- Exclude system databases 
    AND DatabaseID <> 32767  -- Exclude ResourceDB 
ORDER BY a.[CPU_Time_Ms] - b.[CPU_Time_Ms] DESC 
OPTION(RECOMPILE);

-- Cleanup
DROP TABLE IF EXISTS #tbl;
GO

-----------------------------------------------------------------------
-- 6.2 STORED PROCEDURE CPU STATISTICS (DATABASE-LEVEL)
--     Shows top CPU-consuming stored procedures with delta analysis.
--     Run in the target database context.
-----------------------------------------------------------------------
-- First snapshot
IF OBJECT_ID('tempdb.dbo.#t', 'U') IS NOT NULL
    DROP TABLE #t;

SELECT TOP (100) 
    GETDATE() AS ReportedTime,
    DB_NAME() AS database_name,
    p.name AS [SP_Name], 
    qs.total_worker_time AS [TotalWorkerTime], 
    qs.total_worker_time / qs.execution_count AS [AvgWorkerTime], 
    qs.execution_count, 
    ISNULL(qs.execution_count / DATEDIFF(SECOND, qs.cached_time, GETDATE()), 0) AS [Calls_Per_Second],
    qs.total_elapsed_time, 
    qs.total_elapsed_time / qs.execution_count AS [avg_elapsed_time], 
    qs.cached_time
INTO #t
FROM sys.procedures AS p WITH (NOLOCK)
    INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK) 
        ON p.[object_id] = qs.[object_id]
WHERE qs.database_id = DB_ID()
ORDER BY qs.total_worker_time DESC 
OPTION (RECOMPILE);

-- Wait 10 seconds
WAITFOR DELAY '00:00:10';

-- Second snapshot with delta calculation
SELECT 
    t.ReportedTime AS [First_Snapshot_Time], 
    x.[SP_Name], 
    DATEDIFF(SECOND, t.ReportedTime, x.ReportedTime) AS [Seconds_Between_Snapshots],
    x.[TotalWorkerTime] - t.[TotalWorkerTime] AS [Delta_TotalWorkerTime],
    x.[AvgWorkerTime] - t.[AvgWorkerTime] AS [Delta_AvgWorkerTime],
    x.execution_count - t.execution_count AS [Delta_execution_count],
    x.total_elapsed_time - t.total_elapsed_time AS [Delta_total_elapsed_time],
    x.[avg_elapsed_time] - t.[avg_elapsed_time] AS [Delta_avg_elapsed_time]
FROM #t t 
    INNER JOIN (
        SELECT TOP (100) 
            GETDATE() AS ReportedTime,
            DB_NAME() AS database_name,
            p.name AS [SP_Name], 
            qs.total_worker_time AS [TotalWorkerTime], 
            qs.total_worker_time / qs.execution_count AS [AvgWorkerTime], 
            qs.execution_count, 
            ISNULL(qs.execution_count / DATEDIFF(SECOND, qs.cached_time, GETDATE()), 0) AS [Calls_Per_Second],
            qs.total_elapsed_time, 
            qs.total_elapsed_time / qs.execution_count AS [avg_elapsed_time], 
            qs.cached_time
        FROM sys.procedures AS p WITH (NOLOCK)
            INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK) 
                ON p.[object_id] = qs.[object_id]
        WHERE qs.database_id = DB_ID()
        ORDER BY qs.total_worker_time DESC
    ) AS x ON t.[SP_Name] = x.[SP_Name]
ORDER BY x.[TotalWorkerTime] - t.[TotalWorkerTime] DESC;

-- Cleanup
DROP TABLE IF EXISTS #t;
GO

-----------------------------------------------------------------------
-- SECTION 7: CPU PRESSURE INDICATORS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 CPU PRESSURE ANALYSIS VIA WAIT STATISTICS
--     Shows signal waits vs resource waits ratio.
--     High signal waits (>25%) indicate CPU pressure.
--     Note: This clears wait stats - use with caution.
-----------------------------------------------------------------------
-- Clear wait statistics (optional - comment out if not desired)
-- DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
-- GO

-- Analyze signal vs resource waits
SELECT 
    CAST(100.0 * SUM(signal_wait_time_ms) / SUM(wait_time_ms) AS NUMERIC(20,2)) AS [Percent_Signal_CPU_Waits],
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM(wait_time_ms) AS NUMERIC(20,2)) AS [Percent_Resource_Waits]
FROM sys.dm_os_wait_stats;
GO

-----------------------------------------------------------------------
-- SECTION 8: PERFMON/THREAD-LEVEL TROUBLESHOOTING
-----------------------------------------------------------------------

/*
-----------------------------------------------------------------------
-- 8.1 PERFMON APPROACH FOR THREAD-LEVEL ANALYSIS
--     Manual steps to correlate high CPU threads to SQL queries.
-----------------------------------------------------------------------

STEP 1: Launch Perfmon
    - Type 'perfmon' in Windows CMD or launch from Control Panel
    - Click "Add counters" and select "Thread" object
    - Select these counters simultaneously:
        * % Processor Time
        * ID Thread
        * Thread State
        * Thread Wait Reason
    - Select all instances beginning with "sqlservr"

STEP 2: Change to Report View
    - Press Ctrl+R or click "View Report" tab

STEP 3: Identify Problem Thread
    - Note the "ID Thread" and "% Processor Time" values
    - Find the thread with highest CPU usage

STEP 4: Correlate Thread ID (KPID) to SPID
*/

-- Run this query to correlate Thread ID to SQL Server SPID:
-- SELECT spid, kpid, dbid, cpu, memusage 
-- FROM sys.sysprocesses 
-- WHERE kpid = {ID_Thread_From_Perfmon};
-- GO

/*
STEP 5: Get Thread and Transaction Details
*/

-- Run this query to see thread details:
-- SELECT spid, kpid, status, cpu, memusage, open_tran, dbid 
-- FROM sys.sysprocesses 
-- WHERE spid = {SPID_From_Step4};
-- GO

/*
STEP 6: Get Exact Query Text
*/

-- Run DBCC INPUTBUFFER to see the query:
-- DBCC INPUTBUFFER({SPID_From_Step4});
-- GO

-----------------------------------------------------------------------
-- END OF CPU PERFORMANCE ANALYSIS
-----------------------------------------------------------------------
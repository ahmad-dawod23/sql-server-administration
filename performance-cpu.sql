-----------------------------------------------------------------------
-- CPU PERFORMANCE ANALYSIS
-- Purpose : Identify top CPU-consuming queries (active and cached),
--           CPU utilization trends, and scheduler pressure.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. TOP 10 ACTIVE CPU QUERIES BY SESSION
--    Shows currently executing queries ordered by CPU time.
-----------------------------------------------------------------------
SELECT TOP 10
    req.session_id, 
    req.start_time, 
    req.cpu_time AS cpu_time_ms, 
    OBJECT_NAME(st.objectid, st.dbid) AS ObjectName,  
    SUBSTRING(
        REPLACE(REPLACE(
            SUBSTRING(ST.text, (req.statement_start_offset/2) + 1,   
                ((CASE statement_end_offset
                    WHEN -1 THEN DATALENGTH(ST.text)   
                    ELSE req.statement_end_offset 
                END - req.statement_start_offset)/2) + 1), 
            CHAR(10), ' '), 
        CHAR(13), ' '), 
    1, 512) AS statement_text   
FROM sys.dm_exec_requests AS req   
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST 
ORDER BY cpu_time DESC;
GO 

-----------------------------------------------------------------------
-- 2. TOP 10 ACTIVE CPU QUERIES AGGREGATED BY QUERY HASH
--    Aggregates CPU consumption for identical queries.
-----------------------------------------------------------------------
SELECT TOP 10 
    GETDATE() AS runtime,  
    *
FROM (
    SELECT 
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
            SUBSTRING(ST.text, (req.statement_start_offset/2) + 1, 
                ((CASE statement_end_offset
                    WHEN -1 THEN DATALENGTH(ST.text)   
                    ELSE req.statement_end_offset 
                END - req.statement_start_offset)/2) + 1) AS statement_text   
        FROM sys.dm_exec_requests AS req   
            CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST
    ) AS query_stats   
    GROUP BY query_hash
) t 
ORDER BY Total_Request_Cpu_Time_Ms DESC;
GO 

/*
[T3] TOP 15 CPU consuming queries from query store 
-- top 15 CPU consuming queries by query hash 
-- note that a query  hash can have many query id if not parameterized or not parameterized properly 
-- it grabs a sample query text by min  
*/
WITH AggregatedCPU AS (
	SELECT q.query_hash, 
		SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, 
		SUM(count_executions * avg_cpu_time / 1000.0) /SUM(count_executions) as avg_cpu_millisec, 
		max(rs.max_cpu_time/1000.00) as max_cpu_millisec, 
		max(max_logical_io_reads) max_logical_reads, 
		COUNT (distinct p.plan_id) AS number_of_distinct_plans, 
		count (distinct p.query_id) as number_of_distinct_query_ids, 
		sum (case when rs.execution_type_desc='Aborted' then count_executions else 0 end) as Aborted_Execution_Count, 
		sum (case when rs.execution_type_desc='Regular' then count_executions else 0 end) as Regular_Execution_Count, 
		sum (case when rs.execution_type_desc='Exception' then count_executions else 0 end) as Exception_Execution_Count, 
		sum (count_executions) as total_executions, 
		min(qt.query_sql_text) as sampled_query_text 
	FROM sys.query_store_query_text AS qt JOIN sys.query_store_query AS q  
		ON qt.query_text_id = q.query_text_id 
		JOIN sys.query_store_plan AS p ON q.query_id = p.query_id 
		JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id 
		JOIN sys.query_store_runtime_stats_interval AS rsi  
		ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id 
	WHERE   
		rs.execution_type_desc in( 'Regular' , 'Aborted', 'Exception') and   
		rsi.start_time >= DATEADD(hour, -2, GETUTCDATE())  
	GROUP BY  q.query_hash 
) ,OrderedCPU AS ( 
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
-- 4. DETAILED CPU QUERY ANALYSIS WITH EXECUTION PLANS
--    Run in affected user database.
-----------------------------------------------------------------------
SELECT    req.session_id, 
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
-- 5. MANY INDIVIDUAL QUERIES CONSUMING HIGH CPU (Aggregated)
--    Alternative aggregated view for cumulative CPU consumption.
-----------------------------------------------------------------------
SELECT TOP 10 
    GETDATE() AS runtime, 
    *
FROM (
    SELECT 
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
            SUBSTRING(ST.text, (req.statement_start_offset / 2) + 1, 
                ((CASE statement_end_offset 
                    WHEN -1 THEN DATALENGTH(ST.text)
                    ELSE req.statement_end_offset 
                END - req.statement_start_offset) / 2) + 1) AS statement_text
        FROM sys.dm_exec_requests AS req
            CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST
    ) AS query_stats
    GROUP BY query_hash
) AS t
ORDER BY Total_Request_Cpu_Time_Ms DESC;
GO

PRINT '--top 10 Active CPU Consuming Queries by sessions--';
SELECT TOP 10 req.session_id, req.start_time, cpu_time 'cpu_time_ms', OBJECT_NAME(ST.objectid, ST.dbid) 'ObjectName', SUBSTRING(REPLACE(REPLACE(SUBSTRING(ST.text, (req.statement_start_offset / 2)+1, ((CASE statement_end_offset WHEN -1 THEN DATALENGTH(ST.text)ELSE req.statement_end_offset END-req.statement_start_offset)/ 2)+1), CHAR(10), ' '), CHAR(13), ' '), 1, 512) AS statement_text
FROM sys.dm_exec_requests AS req
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST
ORDER BY cpu_time DESC;
GO



--If The CPU issue occurred in the past:


-- Top 15 CPU consuming queries by query hash
-- note that a query  hash can have many query id if not parameterized or not parameterized properly
-- it grabs a sample query text by min
WITH AggregatedCPU AS (SELECT q.query_hash, SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, SUM(count_executions * avg_cpu_time / 1000.0)/ SUM(count_executions) AS avg_cpu_millisec, MAX(rs.max_cpu_time / 1000.00) AS max_cpu_millisec, MAX(max_logical_io_reads) max_logical_reads, COUNT(DISTINCT p.plan_id) AS number_of_distinct_plans, COUNT(DISTINCT p.query_id) AS number_of_distinct_query_ids, SUM(CASE WHEN rs.execution_type_desc='Aborted' THEN count_executions ELSE 0 END) AS Aborted_Execution_Count, SUM(CASE WHEN rs.execution_type_desc='Regular' THEN count_executions ELSE 0 END) AS Regular_Execution_Count, SUM(CASE WHEN rs.execution_type_desc='Exception' THEN count_executions ELSE 0 END) AS Exception_Execution_Count, SUM(count_executions) AS total_executions, MIN(qt.query_sql_text) AS sampled_query_text
                       FROM sys.query_store_query_text AS qt
                            JOIN sys.query_store_query AS q ON qt.query_text_id=q.query_text_id
                            JOIN sys.query_store_plan AS p ON q.query_id=p.query_id
                            JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id=p.plan_id
                            JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id=rs.runtime_stats_interval_id
                       WHERE rs.execution_type_desc IN ('Regular', 'Aborted', 'Exception')AND rsi.start_time>=DATEADD(HOUR, -2, GETUTCDATE())
                       GROUP BY q.query_hash), OrderedCPU AS (SELECT query_hash, total_cpu_millisec, avg_cpu_millisec, max_cpu_millisec, max_logical_reads, number_of_distinct_plans, number_of_distinct_query_ids, total_executions, Aborted_Execution_Count, Regular_Execution_Count, Exception_Execution_Count, sampled_query_text, ROW_NUMBER() OVER (ORDER BY total_cpu_millisec DESC, query_hash ASC) AS RN
                                                              FROM AggregatedCPU)
SELECT OD.query_hash, OD.total_cpu_millisec, OD.avg_cpu_millisec, OD.max_cpu_millisec, OD.max_logical_reads, OD.number_of_distinct_plans, OD.number_of_distinct_query_ids, OD.total_executions, OD.Aborted_Execution_Count, OD.Regular_Execution_Count, OD.Exception_Execution_Count, OD.sampled_query_text, OD.RN
FROM OrderedCPU AS OD
WHERE OD.RN<=15
ORDER BY total_cpu_millisec DESC;




-- Get socket, physical core and logical core count from the SQL Server Error log. (Query 2) (Core Counts)

-- This query might take a few seconds depending on the size of your error log

EXEC sys.xp_readerrorlog 0, 1, N'detected', N'socket';

------







-- SQL Server NUMA Node information  (Query 13) (SQL Server NUMA Info)

SELECT osn.node_id, osn.node_state_desc, osn.memory_node_id, osn.processor_group, osn.cpu_count, osn.online_scheduler_count, 

       osn.idle_scheduler_count, osn.active_worker_count, 

	   osmn.pages_kb/1024 AS [Committed Memory (MB)], 

	   osmn.locked_page_allocations_kb/1024 AS [Locked Physical (MB)],

	   CONVERT(DECIMAL(18,2), osmn.foreign_committed_kb/1024.0) AS [Foreign Commited (MB)],

	   osmn.target_kb/1024 AS [Target Memory Goal (MB)],

	   osn.avg_load_balance, osn.resource_monitor_state

FROM sys.dm_os_nodes AS osn WITH (NOLOCK)

INNER JOIN sys.dm_os_memory_nodes AS osmn WITH (NOLOCK)

ON osn.memory_node_id = osmn.memory_node_id

WHERE osn.node_state_desc <> N'ONLINE DAC' OPTION (RECOMPILE);

------







-- Get processor description from Windows Registry  (Query 21) (Processor Description)

EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString';

------







-- You can learn more about processor selection for SQL Server by following this link

-- https://bit.ly/2F3aVlP













-- Get CPU vectorization level from SQL Server Error log (Query 22) (CPU Vectorization Level) 

IF EXISTS (SELECT * WHERE CONVERT(VARCHAR(2), SERVERPROPERTY('ProductMajorVersion')) = '16')

	BEGIN		

		-- Get CPU Description from Registry (only works on Windows)

		DROP TABLE IF EXISTS #ProcessorDesc;

			CREATE TABLE #ProcessorDesc

			(RegValue NVARCHAR(50), RegKey NVARCHAR(100));





		INSERT INTO #ProcessorDesc (RegValue, RegKey)

		EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString';

		DECLARE @ProcessorDesc NVARCHAR(100) = (SELECT RegKey FROM #ProcessorDesc);





		-- Get CPU Vectorization Level from SQL Server Error Log

		DROP TABLE IF EXISTS #CPUVectorizationLevel;

			CREATE TABLE #CPUVectorizationLevel

			(LogDateTime DATETIME, ProcessInfo NVARCHAR(12), LogText NVARCHAR(200));





		INSERT INTO #CPUVectorizationLevel (LogDateTime, ProcessInfo, LogText)

		EXEC sys.xp_readerrorlog 0, 1, N'CPU vectorization level';

		DECLARE @CPUVectorizationLevel NVARCHAR(200) = (SELECT LogText FROM #CPUVectorizationLevel);





		-- Get TF15097 Status

		DROP TABLE IF EXISTS #TraceFlagStatus;

			CREATE TABLE #TraceFlagStatus

			(TraceFlag smallint, TFStatus tinyint, TFGlobal tinyint, TFSession tinyint);







-- Missing Indexes for all databases by Index Advantage  (Query 36) (Missing Indexes All Databases)

SELECT CONVERT(decimal(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) AS [index_advantage], 

CONVERT(nvarchar(25), migs.last_user_seek, 20) AS [last_user_seek],

mid.[statement] AS [Database.Schema.Table], 

COUNT(1) OVER(PARTITION BY mid.[statement]) AS [missing_indexes_for_table], 

COUNT(1) OVER(PARTITION BY mid.[statement], mid.equality_columns) AS [similar_missing_indexes_for_table], 

mid.equality_columns, mid.inequality_columns, mid.included_columns, migs.user_seeks, 

CONVERT(decimal(18,2), migs.avg_total_user_cost) AS [avg_total_user_,cost], migs.avg_user_impact,

REPLACE(REPLACE(LEFT(st.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text]

FROM sys.dm_db_missing_index_groups AS mig WITH (NOLOCK) 

INNER JOIN sys.dm_db_missing_index_group_stats_query AS migs WITH(NOLOCK) 

ON mig.index_group_handle = migs.group_handle 

CROSS APPLY sys.dm_exec_sql_text(migs.last_sql_handle) AS st 

INNER JOIN sys.dm_db_missing_index_details AS mid WITH (NOLOCK) 

ON mig.index_handle = mid.index_handle 



-- Isolate top waits for server instance since last restart or wait statistics clear  (Query 42) (Top Waits)

WITH [Waits] 

AS (SELECT wait_type, wait_time_ms/ 1000.0 AS [WaitS],

          (wait_time_ms - signal_wait_time_ms) / 1000.0 AS [ResourceS],

           signal_wait_time_ms / 1000.0 AS [SignalS],

           waiting_tasks_count AS [WaitCount],

           100.0 *  wait_time_ms / SUM (wait_time_ms) OVER() AS [Percentage],

           ROW_NUMBER() OVER(ORDER BY wait_time_ms DESC) AS [RowNum]

    FROM sys.dm_os_wait_stats WITH (NOLOCK)

    WHERE [wait_type] NOT IN (

	    N'AZURE_IMDS_VERSIONS',





-- The SQL Server Wait Type Repository

-- https://bit.ly/1afzfjC





-- Wait statistics, or please tell me where it hurts

-- https://bit.ly/2wsQHQE





-- SQL Server 2005 Performance Tuning using the Waits and Queues

-- https://bit.ly/1o2NFoF





-- sys.dm_os_wait_stats (Transact-SQL)

-- https://bit.ly/2Hjq9Yl















-- This helps you figure where your database load is coming from

-- and verifies connectivity from other machines





-- Solving Connectivity errors to SQL Server

-- https://bit.ly/2EgzoD0













-- Get Average Task Counts (run multiple times)  (Query 44) (Avg Task Counts)

SELECT AVG(current_tasks_count) AS [Avg Task Count], 

AVG(work_queue_count) AS [Avg Work Queue Count],

AVG(runnable_tasks_count) AS [Avg Runnable Task Count],

AVG(pending_disk_io_count) AS [Avg Pending DiskIO Count],

GETDATE() AS [System Time]

FROM sys.dm_os_schedulers WITH (NOLOCK)



-- sys.dm_db_log_info (Transact-SQL)

-- https://bit.ly/2EQUU1v













-- Get database scoped configuration values for current database (Query 60) (Database-scoped Configurations)

SELECT configuration_id, name, [value] AS [value_for_primary], value_for_secondary, is_value_default

FROM sys.database_scoped_configurations WITH (NOLOCK) OPTION (RECOMPILE);

------





-- This lets you see the value of these new properties for the current database





-- Clear plan cache for current database
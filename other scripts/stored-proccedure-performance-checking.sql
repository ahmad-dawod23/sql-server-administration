
/*******************************************************************************
 SECTION 10: STORED PROCEDURE PERFORMANCE ANALYSIS
 Purpose: Analyze stored procedure performance and resource consumption
 Note: All stored procedure-specific queries are grouped here
*******************************************************************************/

-----------------------------------------------------------------------
-- 10.1 TOP STORED PROCEDURES BY TOTAL LOGICAL WRITES
--      Logical writes relate to both memory and disk I/O pressure
--      High logical writes indicate heavy data modification or scanning
-----------------------------------------------------------------------
SELECT TOP(25)
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name],
    qs.total_logical_writes AS [TotalLogicalWrites],
    qs.total_logical_writes/qs.execution_count AS [AvgLogicalWrites],
    qs.execution_count,
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
    qs.total_elapsed_time,
    qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
         LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
    -- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
    INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
        ON p.[object_id] = qs.[object_id]
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
  AND qs.total_logical_writes > 0
  AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY qs.total_logical_writes DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 10.2 TOP STORED PROCEDURES BY AVERAGE ELAPSED TIME
--      Identifies cached stored procedures with highest average elapsed time
--      Helps identify slow-running stored procedures
-----------------------------------------------------------------------
SELECT TOP(25) 
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], 
    qs.min_elapsed_time, 
    qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time], 
    qs.max_elapsed_time, 
    qs.last_elapsed_time, 
    qs.total_elapsed_time, 
    qs.execution_count, 
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute], 
    qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], 
    qs.total_worker_time AS [TotalWorkerTime],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2
        LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    qs.cached_time AS [Plan Cached Time]
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
    ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
    AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY avg_elapsed_time DESC OPTION (RECOMPILE);
GO



-----------------------------------------------------------------------
-- 5.2 STORED PROCEDURE CPU STATISTICS (DATABASE-LEVEL)
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

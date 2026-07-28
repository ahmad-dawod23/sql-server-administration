
/*******************************************************************************
 SECTION 10: STORED PROCEDURE PERFORMANCE ANALYSIS
 Purpose: Analyze stored procedure performance and resource consumption
 Note: All stored procedure-specific queries are grouped here.

 IMPORTANT: sys.dm_exec_procedure_stats reports *_elapsed_time and
            *_worker_time in MICROSECONDS. Queries below expose
            millisecond (_ms) columns to avoid misreading the values.
            All counters are cumulative since the plan was cached
            (qs.cached_time) and reset when the plan leaves the cache.
*******************************************************************************/
SET NOCOUNT ON;
GO

-----------------------------------------------------------------------
-- 10.1 TOP STORED PROCEDURES BY TOTAL LOGICAL WRITES
--      Logical writes relate to both memory and disk I/O pressure
--      High logical writes indicate heavy data modification or scanning
-----------------------------------------------------------------------
SELECT TOP(25)
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name],
    qs.total_logical_writes AS [TotalLogicalWrites],
    qs.total_logical_writes / qs.execution_count AS [AvgLogicalWrites],
    qs.execution_count,
    ISNULL(qs.execution_count / NULLIF(DATEDIFF(MINUTE, qs.cached_time, GETDATE()), 0), 0) AS [Calls/Minute],
    qs.total_elapsed_time / 1000.0 AS [TotalElapsed_ms],
    (qs.total_elapsed_time / qs.execution_count) / 1000.0 AS [AvgElapsed_ms],
    CASE WHEN qp.query_plan IS NULL THEN NULL   -- plan not retrievable (evicted or XML nesting > 128 levels)
         WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2
              LIKE N'%<MissingIndexes>%' THEN 1
         ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
    -- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
    INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
        ON p.[object_id] = qs.[object_id]
    OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp  -- OUTER, so procs with an unavailable plan are still listed
WHERE qs.database_id = DB_ID()
  AND qs.total_logical_writes > 0
ORDER BY qs.total_logical_writes DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 10.2 TOP STORED PROCEDURES BY AVERAGE ELAPSED TIME
--      Identifies cached stored procedures with highest average elapsed time
--      Helps identify slow-running stored procedures
-----------------------------------------------------------------------
SELECT TOP(25) 
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], 
    qs.min_elapsed_time / 1000.0 AS [MinElapsed_ms],
    (qs.total_elapsed_time / qs.execution_count) / 1000.0 AS [AvgElapsed_ms],
    qs.max_elapsed_time / 1000.0 AS [MaxElapsed_ms],
    qs.last_elapsed_time / 1000.0 AS [LastElapsed_ms],
    qs.total_elapsed_time / 1000.0 AS [TotalElapsed_ms],
    qs.execution_count, 
    ISNULL(qs.execution_count / NULLIF(DATEDIFF(MINUTE, qs.cached_time, GETDATE()), 0), 0) AS [Calls/Minute], 
    (qs.total_worker_time / qs.execution_count) / 1000.0 AS [AvgWorker_ms],
    qs.total_worker_time / 1000.0 AS [TotalWorker_ms],
    CASE WHEN qp.query_plan IS NULL THEN NULL
         WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2
              LIKE N'%<MissingIndexes>%' THEN 1
         ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
    ON p.[object_id] = qs.[object_id]
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
ORDER BY [AvgElapsed_ms] DESC OPTION (RECOMPILE);
GO



-----------------------------------------------------------------------
-- 10.3 STORED PROCEDURE CPU STATISTICS (DATABASE-LEVEL)
--      Shows top CPU-consuming stored procedures with delta analysis.
--      Run in the target database context.
--      WARNING: this block BLOCKS THE SESSION FOR 10 SECONDS between
--               the two snapshots (WAITFOR DELAY below).
-----------------------------------------------------------------------
-- First snapshot
DROP TABLE IF EXISTS #t;

SELECT TOP (100) 
    GETDATE() AS ReportedTime,
    DB_NAME() AS database_name,
    qs.[object_id],
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP_Name], 
    qs.total_worker_time AS [TotalWorkerTime], 
    qs.total_worker_time / qs.execution_count AS [AvgWorkerTime], 
    qs.execution_count, 
    ISNULL(qs.execution_count / NULLIF(DATEDIFF(SECOND, qs.cached_time, GETDATE()), 0), 0) AS [Calls_Per_Second],
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

-- Second snapshot with delta calculation.
-- Joined on object_id (not name) so procedures with the same name in
-- different schemas are not mixed up, and matched on cached_time so a plan
-- that was re-cached between snapshots does not produce negative deltas.
SELECT 
    t.ReportedTime AS [First_Snapshot_Time], 
    x.[SP_Name], 
    DATEDIFF(SECOND, t.ReportedTime, x.ReportedTime) AS [Seconds_Between_Snapshots],
    (x.[TotalWorkerTime] - t.[TotalWorkerTime]) / 1000.0 AS [Delta_TotalWorker_ms],
    (x.[AvgWorkerTime] - t.[AvgWorkerTime]) / 1000.0 AS [Delta_AvgWorker_ms],
    x.execution_count - t.execution_count AS [Delta_execution_count],
    (x.total_elapsed_time - t.total_elapsed_time) / 1000.0 AS [Delta_TotalElapsed_ms],
    (x.[avg_elapsed_time] - t.[avg_elapsed_time]) / 1000.0 AS [Delta_AvgElapsed_ms]
FROM #t AS t 
    INNER JOIN (
        SELECT TOP (100) 
            GETDATE() AS ReportedTime,
            DB_NAME() AS database_name,
            qs.[object_id],
            CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP_Name], 
            qs.total_worker_time AS [TotalWorkerTime], 
            qs.total_worker_time / qs.execution_count AS [AvgWorkerTime], 
            qs.execution_count, 
            ISNULL(qs.execution_count / NULLIF(DATEDIFF(SECOND, qs.cached_time, GETDATE()), 0), 0) AS [Calls_Per_Second],
            qs.total_elapsed_time, 
            qs.total_elapsed_time / qs.execution_count AS [avg_elapsed_time], 
            qs.cached_time
        FROM sys.procedures AS p WITH (NOLOCK)
            INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK) 
                ON p.[object_id] = qs.[object_id]
        WHERE qs.database_id = DB_ID()
        ORDER BY qs.total_worker_time DESC
    ) AS x 
        ON t.[object_id] = x.[object_id]
       AND t.cached_time = x.cached_time   -- same cached plan in both snapshots
WHERE x.execution_count >= t.execution_count
ORDER BY [Delta_TotalWorker_ms] DESC
OPTION (RECOMPILE);

-- Cleanup
DROP TABLE IF EXISTS #t;
GO


-----------------------------------------------------------------------
-- 10.4 STATEMENT-LEVEL DRILL-DOWN INSIDE A STORED PROCEDURE
--      Sections 10.1-10.3 tell you WHICH procedure is expensive;
--      this one tells you WHICH STATEMENT inside it is expensive.
--      Set @sp_name, or leave it NULL to see the top statements across
--      all procedures in the current database.
-----------------------------------------------------------------------
DECLARE @sp_name nvarchar(300) = NULL;  -- e.g. N'dbo.usp_GetOrders'

SELECT TOP (50)
    CONCAT(SCHEMA_NAME(o.schema_id), '.', o.name) AS [SP Name],
    qs.execution_count,
    qs.total_worker_time / 1000.0 AS [TotalWorker_ms],
    (qs.total_worker_time / qs.execution_count) / 1000.0 AS [AvgWorker_ms],
    qs.total_elapsed_time / 1000.0 AS [TotalElapsed_ms],
    (qs.total_elapsed_time / qs.execution_count) / 1000.0 AS [AvgElapsed_ms],
    qs.total_logical_reads,
    qs.total_logical_reads / qs.execution_count AS [AvgLogicalReads],
    qs.total_logical_writes,
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    SUBSTRING(st.[text],
              (qs.statement_start_offset / 2) + 1,
              ((CASE qs.statement_end_offset
                    WHEN -1 THEN DATALENGTH(st.[text])
                    ELSE qs.statement_end_offset
                END - qs.statement_start_offset) / 2) + 1) AS [Statement Text],
    qp.query_plan AS [Statement Plan]
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    INNER JOIN sys.objects AS o WITH (NOLOCK)
        ON st.[objectid] = o.[object_id]
WHERE st.[dbid] = DB_ID()
  AND o.[type] IN ('P', 'PC')   -- SQL and CLR stored procedures
  AND (@sp_name IS NULL OR o.[object_id] = OBJECT_ID(@sp_name))
ORDER BY qs.total_worker_time DESC
OPTION (RECOMPILE);
GO



/**********************************************************************************************/
/*  10.5 RECOMPILE SCRIPT v1.1 / 2014-09-16

	This script marks the stored procedure for recompilation.
	It will automatically retrieve the old + new cached plans (if they exist).

	Note: it will take more than 1 minute to complete (be patient!)
		  Also please make sure to use the correct database.

	IMPORTANT: sp_recompile only *marks* the plan for recompilation - it drops
	           the existing plan from cache. A NEW plan is only created the next
	           time the procedure is actually EXECUTED. If nothing calls the
	           procedure during the 1 minute wait below, the "new_query_plan"
	           result set will legitimately come back empty.
*/

DECLARE @stored_proc_name nvarchar(255) 
	SET @stored_proc_name = 'dbo.STORED_PROC_NAME_HERE' -- example: 'dbo.GetInventoryLegFromList'


DECLARE @object_id int
	SET @object_id = OBJECT_ID(@stored_proc_name,'P') -- type: 'P' = SQL Stored Procedure
DECLARE @rowcount int
	
SET NOCOUNT ON;

IF @object_id IS NULL 
	BEGIN;
		PRINT 'Object not found! Invalid database in use?';
	END;
	ELSE
	BEGIN;

		-- find the old query plan
		SELECT TOP 1 db_name(dbid) as db_name, objectid, objtype, cacheobjtype, usecounts, query_plan as 'old_query_plan'
		FROM sys.dm_exec_cached_plans cp WITH (nolock) CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) x
		WHERE x.objectid = @object_id AND cp.cacheobjtype = 'Compiled plan';
	
		SET @rowcount = @@ROWCOUNT

		-- recompile the stored procedure
		EXEC sp_recompile @stored_proc_name;
		
		IF @rowcount > 0 -- runs only if a cached plan existed
		BEGIN;
			-- wait 1 minute for the procedure to be executed again and re-cached
			WAITFOR DELAY '00:01';
			
			-- find the new query plan
			SELECT TOP 1 db_name(dbid) as db_name, objectid, objtype, cacheobjtype, usecounts, query_plan as 'new_query_plan' 
			FROM sys.dm_exec_cached_plans cp WITH (nolock) CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) x
			WHERE x.objectid = @object_id AND cp.cacheobjtype = 'Compiled plan';		
		END;
		ELSE
			PRINT 'There was no cached plan before recompilation.';
	END;
GO

/**********************************************************************************************/

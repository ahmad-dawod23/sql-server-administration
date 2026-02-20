-----------------------------------------------------------------------
-- PLAN CACHE ANALYSIS
-- Purpose : Analyze plan cache health — detect bloat from single-use
--           plans, find forced/parameterized plans, and identify
--           queries with plan regressions or excessive recompilations.
-- Safety  : All queries are read-only except the commented DBCC
--           FREEPROCCACHE commands.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: PLAN CACHE OVERVIEW & HEALTH
--    These queries provide a high-level view of plan cache health
--    and identify memory waste from single-use plans.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 PLAN CACHE SIZE AND COMPOSITION
--     Shows how much memory the plan cache is consuming by plan type.
-----------------------------------------------------------------------
SELECT
    objtype                                       AS PlanType,
    cacheobjtype                                  AS CacheType,
    COUNT(*)                                      AS PlanCount,
    CAST(SUM(size_in_bytes) / 1048576.0
         AS DECIMAL(18,2))                        AS TotalSizeMB,
    SUM(usecounts)                                AS TotalUseCount,
    AVG(usecounts)                                AS AvgUseCount,
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS SingleUsePlans,
    CAST(100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))              AS SingleUsePct
FROM sys.dm_exec_cached_plans
GROUP BY objtype, cacheobjtype
ORDER BY TotalSizeMB DESC;

-----------------------------------------------------------------------
-- 1.2 PLAN CACHE BLOAT — SINGLE-USE PLANS
--     High single-use plan count wastes memory.
--     Fix: Enable "optimize for ad hoc workloads" or parameterize.
-----------------------------------------------------------------------
SELECT
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS SingleUsePlans,
    COUNT(*)                                        AS TotalPlans,
    CAST(100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                AS SingleUsePct,
    CAST(SUM(CASE WHEN usecounts = 1 THEN size_in_bytes ELSE 0 END)
         / 1048576.0 AS DECIMAL(18,2))              AS SingleUseMB,
    CAST(SUM(size_in_bytes) / 1048576.0
         AS DECIMAL(18,2))                          AS TotalCacheMB,
    CASE
        WHEN 100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)
             / COUNT(*) > 50
            THEN '*** ENABLE optimize for ad hoc workloads ***'
        ELSE 'OK'
    END                                             AS Recommendation
FROM sys.dm_exec_cached_plans;

-----------------------------------------------------------------------
-- 1.3 TOP 50 SINGLE-USE AD HOC QUERIES (by size)
--     Find single-use, ad-hoc and prepared queries bloating the plan cache.
--     These queries are executed once and never reused.
--     Reference: https://bit.ly/2EfYOkl
-----------------------------------------------------------------------
SELECT TOP(50) 
    DB_NAME(t.[dbid]) AS [Database Name],
    REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text], 
    cp.objtype AS [Object Type], 
    cp.cacheobjtype AS [Cache Object Type],  
    cp.size_in_bytes/1024 AS [Plan Size in KB],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
        LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index]
    --,t.[text] AS [Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_cached_plans AS cp WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp
WHERE cp.cacheobjtype = N'Compiled Plan' 
AND cp.objtype IN (N'Adhoc', N'Prepared') 
AND cp.usecounts = 1
ORDER BY cp.size_in_bytes DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 2: PLAN CACHE CONTENT ANALYSIS
--    Detailed analysis of what's in the plan cache and how plans
--    are being reused.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 TOP 25 MOST EXECUTED PLANS (plan reuse check)
-----------------------------------------------------------------------
SELECT TOP 25
    cp.usecounts                                  AS ExecutionCount,
    cp.objtype                                    AS PlanType,
    cp.size_in_bytes / 1024                       AS PlanSizeKB,
    SUBSTRING(st.[text], 1, 200)                  AS QueryText,
    qp.query_plan                                 AS QueryPlan,
    qs.total_worker_time / qs.execution_count     AS AvgCPU_us,
    qs.total_logical_reads / qs.execution_count   AS AvgLogicalReads,
    qs.total_elapsed_time / qs.execution_count    AS AvgDuration_us
FROM sys.dm_exec_cached_plans cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
    CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
    LEFT JOIN sys.dm_exec_query_stats qs
        ON cp.plan_handle = qs.plan_handle
WHERE cp.cacheobjtype = 'Compiled Plan'
ORDER BY cp.usecounts DESC;

-----------------------------------------------------------------------
-- 2.2 TOP 25 LARGEST PLANS IN CACHE
--     Large plans consume significant memory.
-----------------------------------------------------------------------
SELECT TOP 25
    cp.size_in_bytes / 1024                       AS PlanSizeKB,
    cp.objtype                                    AS PlanType,
    cp.usecounts                                  AS UseCount,
    SUBSTRING(st.[text], 1, 200)                  AS QueryText,
    DB_NAME(st.dbid)                              AS DatabaseName
FROM sys.dm_exec_cached_plans cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
ORDER BY cp.size_in_bytes DESC;

-----------------------------------------------------------------------
-- SECTION 3: PERFORMANCE ANALYSIS (FROM PLAN CACHE)
--    Identify resource-intensive queries cached in the plan cache.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 TOP 25 CPU-INTENSIVE QUERIES (from plan cache)
-----------------------------------------------------------------------
SELECT TOP 25
    qs.total_worker_time                          AS TotalCPU_us,
    qs.execution_count                            AS Executions,
    qs.total_worker_time / qs.execution_count     AS AvgCPU_us,
    qs.total_logical_reads                        AS TotalReads,
    qs.total_logical_reads / qs.execution_count   AS AvgReads,
    qs.total_elapsed_time / qs.execution_count    AS AvgDuration_us,
    qs.creation_time                              AS PlanCreationTime,
    qs.last_execution_time                        AS LastExecution,
    SUBSTRING(st.[text],
        (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.[text])
            ELSE qs.statement_end_offset
          END - qs.statement_start_offset) / 2) + 1) AS QueryText,
    DB_NAME(st.dbid)                              AS DatabaseName,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
ORDER BY qs.total_worker_time DESC;

-----------------------------------------------------------------------
-- 3.2 TOP 25 QUERIES BY LOGICAL READS (I/O pressure)
-----------------------------------------------------------------------
SELECT TOP 25
    qs.total_logical_reads                        AS TotalReads,
    qs.execution_count                            AS Executions,
    qs.total_logical_reads / qs.execution_count   AS AvgReads,
    qs.total_worker_time / qs.execution_count     AS AvgCPU_us,
    qs.total_elapsed_time / qs.execution_count    AS AvgDuration_us,
    qs.last_execution_time                        AS LastExecution,
    SUBSTRING(st.[text],
        (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.[text])
            ELSE qs.statement_end_offset
          END - qs.statement_start_offset) / 2) + 1) AS QueryText,
    DB_NAME(st.dbid)                              AS DatabaseName
FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_logical_reads DESC;

-----------------------------------------------------------------------
-- SECTION 4: PLAN CACHE ISSUES & DIAGNOSTICS
--    Identify problematic patterns like parameter sniffing and
--    excessive recompilations.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 QUERIES WITH MULTIPLE PLANS (parameter sniffing candidates)
--     Multiple plans for the same query_hash often indicates
--     parameter sniffing issues.
-----------------------------------------------------------------------
SELECT
    query_hash,
    COUNT(DISTINCT query_plan_hash)               AS DistinctPlans,
    COUNT(*)                                      AS TotalEntries,
    SUM(execution_count)                          AS TotalExecutions,
    MIN(SUBSTRING(st.[text], 1, 200))             AS SampleQueryText,
    DB_NAME(MIN(st.dbid))                         AS DatabaseName
FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
GROUP BY query_hash
HAVING COUNT(DISTINCT query_plan_hash) > 1
ORDER BY COUNT(DISTINCT query_plan_hash) DESC;

-----------------------------------------------------------------------
-- 4.2 QUERIES WITH EXCESSIVE RECOMPILATIONS
-----------------------------------------------------------------------
SELECT TOP 25
    qs.plan_generation_num                        AS Recompilations,
    qs.execution_count                            AS Executions,
    qs.total_worker_time / qs.execution_count     AS AvgCPU_us,
    qs.creation_time                              AS PlanCreationTime,
    SUBSTRING(st.[text], 1, 200)                  AS QueryText,
    DB_NAME(st.dbid)                              AS DatabaseName
FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.plan_generation_num > 1
ORDER BY qs.plan_generation_num DESC;

-----------------------------------------------------------------------
-- SECTION 5: QUERY STORE & PLAN MANAGEMENT
--    Manage query plans using Query Store and Plan Guides.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 FORCED PLANS (Query Store)
--     Lists all queries where a plan has been manually forced.
-----------------------------------------------------------------------
SELECT
    qsp.plan_id,
    qsp.query_id,
    qsp.is_forced_plan,
    qsp.force_failure_count,
    qsp.last_force_failure_reason_desc,
    qsqt.query_sql_text,
    qsp.last_execution_time,
    qsp.avg_duration / 1000.0                     AS AvgDurationMs,
    qsp.count_executions                          AS Executions
FROM sys.query_store_plan qsp
    JOIN sys.query_store_query qsq
        ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_query_text qsqt
        ON qsq.query_text_id = qsqt.query_text_id
WHERE qsp.is_forced_plan = 1
ORDER BY qsp.last_execution_time DESC;

-----------------------------------------------------------------------
-- 5.2 PLAN GUIDE INVENTORY
--     Lists all plan guides in the current database.
-----------------------------------------------------------------------
SELECT
    [name]                 AS PlanGuideName,
    scope_type_desc        AS ScopeType,
    is_disabled,
    create_date,
    modify_date,
    SUBSTRING(query_text, 1, 200) AS QueryText,
    hints
FROM sys.plan_guides
ORDER BY [name];

-----------------------------------------------------------------------
-- SECTION 6: PLAN CACHE MAINTENANCE
--    Commands for clearing and managing the plan cache.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 PLAN CACHE CLEANUP COMMANDS (use with caution!)
-----------------------------------------------------------------------
-- Clear entire plan cache (NEVER in production without reason):
-- DBCC FREEPROCCACHE;

-- Clear a specific plan:
-- DBCC FREEPROCCACHE (0x06000700A2C8E72620...)  -- plan_handle

-- Clear single-use plans only (safe):
-- DBCC FREESYSTEMCACHE ('SQL Plans') -- clears adhoc and prepared plans

-- Better approach — enable this server setting:
-- EXEC sp_configure 'optimize for ad hoc workloads', 1;
-- RECONFIGURE;


-- Get plans from cache
select usecounts, cacheobjtype, objtype, TEXT, query_plan, *
from sys.dm_exec_cached_plans
         cross apply sys.dm_exec_sql_text(plan_handle)
         cross apply sys.dm_exec_query_plan(plan_handle) qp
where qp.objectid in ('1522104463', '816826072')



/*******************************************************************************
 SECTION 5: PLAN CACHE ANALYSIS
 Purpose: Analyze procedure cache distribution and usage
*******************************************************************************/

-----------------------------------------------------------------------
-- 5.1 PROCEDURE CACHE DISTRIBUTION
--     Shows how the procedure cache is distributed by object type
-----------------------------------------------------------------------
SELECT
    cacheobjtype, 
    objtype, 
    COUNT(*) AS CountofPlans, 
    SUM(usecounts) AS UsageCount,
    SUM(usecounts)/CAST(count(*) AS float) AS AvgUsed, 
    SUM(size_in_bytes)/1024./1024. AS SizeinMB
FROM sys.dm_exec_cached_plans
GROUP BY cacheobjtype, objtype
ORDER BY CountOfPlans DESC;
GO

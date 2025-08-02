
--Identifying queries that consume the most tempdb resources is crucial for diagnosing performance bottlenecks and optimizing your SQL Server environment. tempdb is used for operations like --sorting, hashing, temporary tables, table variables, and spools. Excessive usage can lead to contention and performance degradation.

--Below are several methods to identify queries consuming the most tempdb:

--1. Use Dynamic Management Views (DMVs)
--SQL Server provides DMVs that track session- and query-level resource usage, including tempdb.

--a. Find Queries with High TempDB Usage
--The following query identifies sessions and queries with high tempdb usage:


SELECT 
    s.session_id,
    r.request_id,
    t.task_alloc_page_count AS TotalAllocatedPages,
    t.task_dealloc_page_count AS TotalDeallocatedPages,
    t.task_alloc_page_count - t.task_dealloc_page_count AS NetTempDBPages,
    t.sql_handle,
    t.plan_handle,
    st.text AS QueryText,
    qp.query_plan AS QueryPlan
FROM sys.dm_db_task_space_usage t
JOIN sys.dm_exec_sessions s ON t.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests r ON t.session_id = r.session_id AND t.request_id = r.request_id
OUTER APPLY sys.dm_exec_sql_text(t.sql_handle) st
OUTER APPLY sys.dm_exec_query_plan(t.plan_handle) qp
WHERE t.session_id > 50 





-- Exclude system sessions
--ORDER BY NetTempDBPages DESC;

--Key Columns:
--task_alloc_page_count: Pages allocated in tempdb.
--task_dealloc_page_count: Pages deallocated from tempdb.
--NetTempDBPages: Net pages consumed by the query.
--QueryText: The SQL query text.
--QueryPlan: The execution plan of the query.
--b. Aggregate TempDB Usage by Session
--To find sessions consuming the most tempdb, use the following query:



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


----------------------------------------------------------------------------------------------------------------
------- tempdb extended event
----------------------------------------------------------------------------------------------------------------
--2. Monitor TempDB Usage with Extended Events
--Extended Events can capture detailed information about tempdb usage.

--a. Create an Extended Events Session
--Create a session to track tempdb allocation and deallocation events:


CREATE EVENT SESSION [Monitor_TempDB_Usage] ON SERVER
ADD EVENT sqlserver.databases_log_file_used_size_changed(
    WHERE database_id = DB_ID('tempdb')),
ADD EVENT sqlserver.databases_data_file_size_changed(
    WHERE database_id = DB_ID('tempdb'))
ADD TARGET package0.event_file(SET filename = N'C:\Path\To\TempDBUsage.xel')
WITH (STARTUP_STATE = ON);
GO

ALTER EVENT SESSION [Monitor_TempDB_Usage] ON SERVER STATE = START;

--b. Analyze the Data
--Query the .xel file to analyze tempdb usage:


SELECT 
    event_data.value('(event/@name)[1]', 'nvarchar(max)') AS EventName,
    event_data.value('(event/data[@name="database_id"]/value)[1]', 'int') AS DatabaseID,
    event_data.value('(event/data[@name="file_id"]/value)[1]', 'int') AS FileID,
    event_data.value('(event/data[@name="size"]/value)[1]', 'bigint') AS SizeInBytes
FROM sys.fn_xe_file_target_read_file('C:\Path\To\TempDBUsage*.xel', NULL, NULL, NULL);

-------------------------------------------------------------------------------------------------------------







SELECT 
    qs.plan_handle,
    qs.execution_count,
    qs.total_worker_time,
    qs.total_logical_reads,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.exist('//RelOp[@PhysicalOp="Hash Match"]') = 1
   OR qp.query_plan.exist('//RelOp[@PhysicalOp="Sort"]') = 1
ORDER BY qs.total_logical_reads DESC;


--b. Check for Worktables

SELECT 
    SUM(user_object_reserved_page_count) * 8 AS UserObjectsKB,
    SUM(internal_object_reserved_page_count) * 8 AS InternalObjectsKB,
    SUM(version_store_reserved_page_count) * 8 AS VersionStoreKB,
    SUM(unallocated_extent_page_count) * 8 AS FreeSpaceKB
FROM sys.dm_db_file_space_usage;


--UserObjectsKB: Space used by user-created objects (e.g., temporary tables).
--InternalObjectsKB: Space used by internal objects (e.g., worktables, spills).
--VersionStoreKB: Space used for row versioning (e.g., snapshot isolation).



SELECT 
    r.session_id,
    r.start_time,
    r.status,
    r.command,
    r.total_elapsed_time / 1000 AS ElapsedTimeInSeconds,
    t.text AS QueryText
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.total_elapsed_time > 60000 -- Queries running longer than 60 seconds
ORDER BY r.total_elapsed_time DESC;


--Conclusion
--To identify queries consuming the most tempdb:
--Use DMVs (sys.dm_db_task_space_usage, sys.dm_db_session_space_usage) to track allocations.
--Monitor tempdb usage with Extended Events or PerfMon.
--Analyze query plans for hash/sort operators and worktables.

--Check cumulative tempdb allocation statistics.
--Identify long-running queries that may be consuming excessive resources.
--By combining these methods, you can pinpoint the queries and sessions responsible for high tempdb usage and take steps to optimize them.
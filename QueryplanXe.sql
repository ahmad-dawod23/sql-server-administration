



--please run this query find the query hash of the slow insert query

SELECT
		text =   IIF(LEFT(text,1) = '(', TRIM(')' FROM SUBSTRING( text, (PATINDEX( '%)[^),]%', text))+1, LEN(text))), text) ,
		start_time,
		elapsed_time_s = total_elapsed_time /1000.0,
		DB_name(database_id) as database_name,
		query_hash  ,
		command,
		execution_type_desc = status
		, sql_handle
FROM    sys.dm_exec_requests
		CROSS APPLY sys.dm_exec_sql_text(sql_handle)
WHERE session_id <> @@SPID





--- actual query plan finder

CREATE EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER 
ADD EVENT sqlserver.query_post_execution_showplan(
    ACTION(
        sqlserver.database_id,
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.session_id
    )
    WHERE (
        sqlserver.query_hash = 0x1234567890ABCDEF -- Replace with your actual query_hash
    )
)
ADD TARGET package0.ring_buffer
WITH (
    MAX_MEMORY = 50MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-- Start the session
ALTER EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER STATE = START;






-- Pull XML actual execution plan from ring buffer and format for saving
SELECT 
    event_data.value('(event/data[@name="query_plan"]/value)[1]', 'nvarchar(max)') AS [ActualExecutionPlanXml]
INTO #PlanXmlTemp
FROM (
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_sessions AS s
    JOIN sys.dm_xe_session_targets AS t
        ON s.address = t.event_session_address
    WHERE s.name = 'Capture_Actual_Plans_By_Hash'
      AND t.target_name = 'ring_buffer'
) AS Data
CROSS APPLY TargetData.nodes('RingBufferTarget/event') AS XEvent(event_data);

-- View or copy/paste the result into a .sqlplan file
SELECT * FROM #PlanXmlTemp;
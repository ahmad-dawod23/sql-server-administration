

-----------------------------------------------------------------------
-- 5.4 Physical Location Formatter
--      Display physical location of rows in a table
--      Format: (file_id:page_id:slot_id)
-----------------------------------------------------------------------
/*
-- Example using AdventureWorks2012
SELECT
    sys.fn_PhysLocFormatter(%%physloc%%) AS [Physical Location],
    BusinessEntityID,
    FirstName,
    LastName
FROM [AdventureWorks2012].[Person].[Person]
WHERE BusinessEntityID < 100
ORDER BY [Physical Location];
GO
*/


/*******************************************************************************
   SECTION 2: NETWORK PROTOCOL & CONNECTION SECURITY
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 Current Session Network Protocol
--      Identify the transport protocol for your current connection
-----------------------------------------------------------------------
SELECT
    session_id,
    net_transport,
    protocol_type,
    auth_scheme,
    encrypt_option
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
GO

-----------------------------------------------------------------------
-- 2.2 Non-Encrypted TDS Connections (Azure SQL MI)
--      Find unencrypted connections that aren't using Shared Memory
--      and aren't internal AG/MI Link traffic
-----------------------------------------------------------------------
SELECT DISTINCT
    net_transport                AS [Transport Protocol],
    protocol_type                AS [Protocol Type],
    endpoint_id                  AS [Endpoint Id],
    auth_scheme                  AS [Authentication Scheme],
    COUNT(*)                     AS ConnectionCount
FROM sys.dm_exec_connections
WHERE encrypt_option != 'TRUE'
  AND net_transport != 'Shared memory'
  AND (
        client_net_address COLLATE database_default
            NOT IN (SELECT ip_address_or_FQDN COLLATE database_default
                    FROM sys.dm_hadr_fabric_nodes)
        OR protocol_type != 'Database Mirroring'
      )
GROUP BY net_transport, protocol_type, endpoint_id, auth_scheme
ORDER BY ConnectionCount DESC;
GO



/*******************************************************************************
   SECTION 3: DATABASE INFORMATION QUERIES
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 List All Databases
-----------------------------------------------------------------------
SELECT
    database_id,
    name AS database_name,
    state_desc,
    recovery_model_desc,
    compatibility_level
FROM sys.databases
ORDER BY name;
GO

-----------------------------------------------------------------------
-- 3.2 Get Database ID by Name
-----------------------------------------------------------------------
-- SELECT DB_ID('AdventureWorks2012');
-- GO

-----------------------------------------------------------------------
-- 3.3 Get Database Name by ID
-----------------------------------------------------------------------
-- SELECT DB_NAME(8);
-- GO


/*******************************************************************************
   SECTION 4: DMV REFERENCE GUIDE
   
   Quick reference for Dynamic Management Views and Functions organized by prefix.
*******************************************************************************/

/*
   sys.dm_exec_%  -- Execution and Connection
      Provides information about connections, sessions, requests, and query execution.
      Example: sys.dm_exec_sessions provides one row for every session currently
               connected to the server.

   sys.dm_os_%    -- SQL OS Related Information
      Provides access to SQL OS related information.
      Example: sys.dm_os_performance_counters provides access to SQL Server performance
               counters without the need to access them using operating system tools.

   sys.dm_tran_%  -- Transaction Management
      Provides access to transaction management information.
      Example: sys.dm_tran_active_transactions provides details of currently active
               transactions.

   sys.dm_io_%    -- I/O Related Information
      Provides information on I/O processes.
      Example: sys.dm_io_virtual_file_stats provides details of I/O performance and
               statistics for each database file.

   sys.dm_db_%    -- Database Scoped Information
      Provides database-scoped information.
      Example: sys.dm_db_index_usage_stats provides information about how each index
               in the database has been used.
*/


-----------------------------------------------------------------------
-- CPU INFORMATION QUERIES
-- Purpose: Retrieve CPU hardware and configuration information,
--          NUMA topology, and processor specifications.
-- Safety: All queries are read-only.
-- Applies to: On-prem / Azure SQL MI (Windows-specific where noted)
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

-----------------------------------------------------------------------
-- SECTION 1: CPU HARDWARE & CONFIGURATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 GET SOCKET, PHYSICAL CORE AND LOGICAL CORE COUNT
--     Reads from SQL Server Error log.
--     Note: This query might take a few seconds depending on error log size.
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'detected', N'socket';
GO

-----------------------------------------------------------------------
-- 1.2 GET PROCESSOR DESCRIPTION FROM WINDOWS REGISTRY
--     Shows processor model and specifications (Windows only).
-----------------------------------------------------------------------
EXEC sys.xp_instance_regread 
    N'HKEY_LOCAL_MACHINE', 
    N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 
    N'ProcessorNameString';
GO

-----------------------------------------------------------------------
-- 1.3 SQL SERVER NUMA NODE INFORMATION
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
-- 1.4 GET CPU VECTORIZATION LEVEL (SQL Server 2022+)
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
-- END OF CPU INFORMATION QUERIES
-----------------------------------------------------------------------

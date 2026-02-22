/*******************************************************************************
 * SQL SERVER INFORMATION QUERIES
 * 
 * Purpose: Comprehensive collection of server information and system queries
 *          for SQL Server version, configuration, hardware, and services.
 * 
 * Sections:
 *   1. SYSTEM & SERVICE INFORMATION
 *   2. CPU HARDWARE & CONFIGURATION
 *   3. NETWORK PROTOCOL & CONNECTION SECURITY
 *   4. DATABASE INFORMATION QUERIES
 *   5. DMV REFERENCE GUIDE
 * 
 * Safety: All queries are read-only unless otherwise noted.
 ******************************************************************************/


/*******************************************************************************
   SECTION 1: SYSTEM & SERVICE INFORMATION
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 SQL SERVER VERSION & PATCH LEVEL
--     Check against latest CU: https://aka.ms/sqlserverbuilds
-----------------------------------------------------------------------
SELECT
    SERVERPROPERTY('MachineName')                AS MachineName,
    SERVERPROPERTY('ServerName')                 AS ServerName,
    SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS ComputerNamePhysicalNetBIOS,
    SERVERPROPERTY('InstanceName')               AS [Instance],
    SERVERPROPERTY('ProductVersion')             AS ProductVersion,
    SERVERPROPERTY('ProductMajorVersion')        AS ProductMajorVersion,
    SERVERPROPERTY('ProductMinorVersion')        AS ProductMinorVersion,
    SERVERPROPERTY('ProductBuild')               AS ProductBuild,
    SERVERPROPERTY('ProductLevel')               AS PatchLevel,
    SERVERPROPERTY('ProductUpdateLevel')         AS CULevel,
    SERVERPROPERTY('ProductBuildType')           AS ProductBuildType,
    SERVERPROPERTY('ProductUpdateReference')     AS ProductUpdateReference,
    SERVERPROPERTY('Edition')                    AS Edition,
    SERVERPROPERTY('EngineEdition')              AS EngineEdition,
    SERVERPROPERTY('ProcessID')                  AS ProcessID,
    SERVERPROPERTY('Collation')                  AS Collation,
    SERVERPROPERTY('IsClustered')                AS IsClustered,
    SERVERPROPERTY('IsHadrEnabled')              AS IsHadrEnabled,
    SERVERPROPERTY('HadrManagerStatus')          AS HadrManagerStatus,
    SERVERPROPERTY('IsFullTextInstalled')        AS IsFullTextInstalled,
    SERVERPROPERTY('IsIntegratedSecurityOnly')   AS IsIntegratedSecurityOnly,
    SERVERPROPERTY('FilestreamConfiguredLevel')  AS FilestreamConfiguredLevel,
    SERVERPROPERTY('InstanceDefaultDataPath')    AS InstanceDefaultDataPath,
    SERVERPROPERTY('InstanceDefaultLogPath')     AS InstanceDefaultLogPath,
    SERVERPROPERTY('InstanceDefaultBackupPath')  AS InstanceDefaultBackupPath,
    SERVERPROPERTY('ErrorLogFileName')           AS ErrorLogFileName,
    SERVERPROPERTY('BuildClrVersion')            AS BuildClrVersion,
    SERVERPROPERTY('IsXTPSupported')             AS IsXTPSupported,
    SERVERPROPERTY('IsPolybaseInstalled')        AS IsPolybaseInstalled,
    SERVERPROPERTY('IsAdvancedAnalyticsInstalled') AS IsRServicesInstalled,
    SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS IsTempdbMetadataMemoryOptimized,
    SERVERPROPERTY('IsServerSuspendedForSnapshotBackup') AS IsServerSuspendedForSnapshotBackup,
    SERVERPROPERTY('SuspendedDatabaseCount')     AS SuspendedDatabaseCount,
    @@VERSION                                    AS FullVersion;

-----------------------------------------------------------------------
-- 1.2 SQL SERVER SERVICES INFORMATION
--     Service status, startup type, and service accounts
-----------------------------------------------------------------------
SELECT 
    servicename, 
    process_id, 
    startup_type_desc, 
    status_desc, 
    last_startup_time, 
    service_account, 
    is_clustered, 
    cluster_nodename, 
    [filename], 
    instant_file_initialization_enabled
FROM sys.dm_server_services WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 1.3 HARDWARE & SYSTEM INFORMATION
--     CPU, memory, NUMA configuration, and uptime
-----------------------------------------------------------------------
SELECT 
    cpu_count AS [Logical CPU Count], 
    scheduler_count, 
    (socket_count * cores_per_socket) AS [Physical Core Count], 
    socket_count AS [Socket Count], 
    cores_per_socket, 
    numa_node_count,
    physical_memory_kb/1024 AS [Physical Memory (MB)], 
    max_workers_count AS [Max Workers Count], 
    affinity_type_desc AS [Affinity Type], 
    sqlserver_start_time AS [SQL Server Start Time],
    DATEDIFF(hour, sqlserver_start_time, GETDATE()) AS [SQL Server Up Time (hrs)],
    virtual_machine_type_desc AS [Virtual Machine Type], 
    softnuma_configuration_desc AS [Soft NUMA Configuration], 
    sql_memory_model_desc, 
    container_type_desc
FROM sys.dm_os_sys_info WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 1.4 HOST INFORMATION
--     Platform details for Linux/Container environments
-----------------------------------------------------------------------
SELECT 
    host_platform, 
    host_distribution, 
    host_release, 
    host_service_pack_level, 
    host_sku, 
    os_language_version,
    host_architecture
FROM sys.dm_os_host_info WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 1.5 CLUSTER NODE INFORMATION
--     Shows cluster nodes if SQL Server is in a failover cluster
-----------------------------------------------------------------------
SELECT 
    NodeName, 
    status_description, 
    is_current_owner
FROM sys.dm_os_cluster_nodes WITH (NOLOCK) 
OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 1.6 SYSTEM MANUFACTURER
--     Hardware manufacturer information from SQL Server Error Log
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'Manufacturer';

-----------------------------------------------------------------------
-- 1.7 BIOS DATE
--     BIOS release date from Windows Registry
-----------------------------------------------------------------------
EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\BIOS', N'BiosReleaseDate';

-----------------------------------------------------------------------
-- 1.8 ACCELERATOR STATUS
--     GPU and hardware acceleration status
-----------------------------------------------------------------------
SELECT 
    accelerator, 
    accelerator_desc, 
    config, 
    config_in_use, 
    mode, 
    mode_desc, 
    mode_reason, 
    mode_reason_desc, 
    accelerator_hardware_detected, 
    accelerator_library_version, 
    accelerator_driver_version
FROM sys.dm_server_accelerator_status WITH (NOLOCK) 
OPTION (RECOMPILE);


/*******************************************************************************
   SECTION 2: CPU HARDWARE & CONFIGURATION
*******************************************************************************/

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

-----------------------------------------------------------------------
-- 2.1 GET SOCKET, PHYSICAL CORE AND LOGICAL CORE COUNT
--     Reads from SQL Server Error log.
--     Note: This query might take a few seconds depending on error log size.
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'detected', N'socket';
GO

-----------------------------------------------------------------------
-- 2.2 GET PROCESSOR DESCRIPTION FROM WINDOWS REGISTRY
--     Shows processor model and specifications (Windows only).
-----------------------------------------------------------------------
EXEC sys.xp_instance_regread 
    N'HKEY_LOCAL_MACHINE', 
    N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 
    N'ProcessorNameString';
GO

-----------------------------------------------------------------------
-- 2.3 SQL SERVER NUMA NODE INFORMATION
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
-- 2.4 GET CPU VECTORIZATION LEVEL (SQL Server 2022+)
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


/*******************************************************************************
   SECTION 3: NETWORK PROTOCOL & CONNECTION SECURITY
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 Current Session Network Protocol
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



/*******************************************************************************
   SECTION 4: DATABASE INFORMATION QUERIES
*******************************************************************************/

-----------------------------------------------------------------------
-- 4.1 List All Databases
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
-- 4.2 Get Database ID by Name
-----------------------------------------------------------------------
-- SELECT DB_ID('AdventureWorks2012');
-- GO

-----------------------------------------------------------------------
-- 4.3 Get Database Name by ID
-----------------------------------------------------------------------
-- SELECT DB_NAME(8);
-- GO

-----------------------------------------------------------------------
-- 4.4 Physical Location Formatter
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
   SECTION 5: DMV REFERENCE GUIDE
   
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

/*******************************************************************************
   END OF FILE
*******************************************************************************/

/*==============================================================================
  DISK SPACE, FILE MANAGEMENT & TRANSACTION LOG HEALTH
  
  Purpose : Monitor volume free space, database file sizes, autogrowth
            events, VLF counts, and log space usage.
  Safety  : All queries are read-only except the DBCC commands which
            are also read-only.
  
  TABLE OF CONTENTS:
  ==================
  SECTION A: DISK & VOLUME SPACE MONITORING
    A1. Volume Free Space (All Database Files)
    A2. LUN Names Used by Instance
        A3. Fixed Drives Enumeration
  
  SECTION B: DATABASE FILE MANAGEMENT
    B1. Database File Sizes - Current Database
    B2. Database File Sizes - All Databases
    B3. Database File Sizes with Growth Recommendations
    B4. Database Filenames and Paths (All Databases)
    B5. Database Size Summary (All Databases)
    B6. Percent-Growth File Audit
    B7. Autogrowth Events (from Default Trace)
    B8. Database File Locations (Simple)
    B9. File Growth Settings Check
    B10. Largest Databases on Specific Drive
    B11. Logical File Names (Ordered by Type)
    B12. Database Sizes (User Databases Only)
    B13. Space Used by Files (Detailed)
    B14. Space Used by All Databases and Files
    B15. LUN Space Monitoring (All Databases)
    B16. LUN Space Monitoring (Specific LUNs)
    B17. Table Storage Analysis
    B18. Allocation Units by File and Partition
  
  SECTION C: TEMPDB FILE MANAGEMENT
    C1. TempDB Data Files Count (from Error Log)
    C2. TempDB Space Usage by Object Type
  
  SECTION D: TRANSACTION LOG MANAGEMENT
    D1. Transaction Log Space Usage (DBCC Method)
    D2. Transaction Log Space Usage (DMV Method)
    D3. Log Reuse Wait Reason (All Databases)
    D4. VLF Count (Current Database)
    D5. VLF Count (All Databases)
==============================================================================*/


/*==============================================================================
  SECTION A: DISK & VOLUME SPACE MONITORING
==============================================================================*/

-----------------------------------------------------------------------
-- A1. VOLUME FREE SPACE (all database files)
--     Shows free space on every volume that hosts a database file.
-----------------------------------------------------------------------
SELECT DISTINCT
    vs.volume_mount_point                        AS Drive,
    vs.logical_volume_name                       AS VolumeName,
    vs.file_system_type                          AS FileSystemType,
    CAST(vs.total_bytes  / 1073741824.0 AS DECIMAL(18,2)) AS TotalGB,
    CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(18,2)) AS FreeGB,
    CAST(100.0 * vs.available_bytes / vs.total_bytes AS DECIMAL(5,2)) AS FreePct,
    vs.supports_compression                      AS SupportsCompression,
    vs.is_compressed                             AS IsCompressed,
    vs.supports_sparse_files                     AS SupportsSparseFiles,
    vs.supports_alternate_streams                AS SupportsAlternateStreams,
    CASE
        WHEN 100.0 * vs.available_bytes / vs.total_bytes < 10
            THEN '*** LOW SPACE ***'
        WHEN 100.0 * vs.available_bytes / vs.total_bytes < 20
            THEN '* Warning *'
        ELSE 'OK'
    END                                          AS [Status]
FROM sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs
ORDER BY FreePct ASC;

-----------------------------------------------------------------------
-- A2. LUN NAMES USED BY INSTANCE
--     Shows all unique drive/LUN paths used by the SQL Server instance
-----------------------------------------------------------------------
SELECT DISTINCT 
    SUBSTRING(physical_name, 0, CHARINDEX('\', physical_name, 6)) AS LUNPath
FROM sys.master_files
ORDER BY LUNPath;

-----------------------------------------------------------------------
-- A3. FIXED DRIVES ENUMERATION (SQL Server 2017+)
--     Shows all fixed drives on the server (not limited to SQL files).
-----------------------------------------------------------------------
SELECT *
FROM sys.dm_os_enumerate_fixed_drives;


/*==============================================================================
  SECTION B: DATABASE FILE MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- B1. DATABASE FILE SIZES — Current Database
--     Shows current size, space used, free space, and autogrowth settings.
-----------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id)                       AS DatabaseName,
    mf.[name]                                     AS LogicalName,
    mf.type_desc                                  AS FileType,
    mf.physical_name                              AS PhysicalPath,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))  AS CurrentSizeMB,
    CAST(FILEPROPERTY(mf.[name], 'SpaceUsed')
        * 8.0 / 1024 AS DECIMAL(18,2))           AS UsedMB,
    CAST((mf.size - FILEPROPERTY(mf.[name], 'SpaceUsed'))
        * 8.0 / 1024 AS DECIMAL(18,2))           AS FreeMB,
    CASE mf.is_percent_growth
        WHEN 1 THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
        ELSE CAST(mf.growth * 8 / 1024 AS VARCHAR(10)) + ' MB'
    END                                           AS AutoGrowth,
    CASE
        WHEN mf.max_size = -1  THEN 'Unlimited'
        WHEN mf.max_size = 0   THEN 'No growth'
        ELSE CAST(CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
    END                                           AS MaxSize,
    mf.is_percent_growth                          AS IsPercentGrowth
FROM sys.master_files mf
WHERE mf.database_id = DB_ID()  -- change or remove for all databases
ORDER BY mf.type_desc, mf.[name];

-----------------------------------------------------------------------
-- B2. DATABASE FILE SIZES — All Databases
--     Basic file information for all databases via sys.master_files
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    [name]                                        AS LogicalName,
    type_desc                                     AS FileType,
    physical_name                                 AS PhysicalPath,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS CurrentSizeMB,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR(10)) + ' MB'
    END                                           AS AutoGrowth
FROM sys.master_files
ORDER BY DB_NAME(database_id), type_desc;

-----------------------------------------------------------------------
-- B3. DATABASE FILE SIZES — All Databases with Growth Recommendations
--     Identifies percent growth and small fixed growth settings
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    [name]                                        AS LogicalName,
    type_desc                                     AS FileType,
    physical_name                                 AS PhysicalPath,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS CurrentSizeMB,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR(10)) + ' MB'
    END                                           AS AutoGrowth,
    CASE
        WHEN is_percent_growth = 1
            THEN '*** CHANGE TO FIXED SIZE ***'
        WHEN growth * 8 / 1024 < 64 AND type_desc = 'ROWS'
            THEN '* Consider larger growth *'
        ELSE 'OK'
    END                                           AS GrowthRecommendation
FROM sys.master_files
ORDER BY DB_NAME(database_id), type_desc;

-----------------------------------------------------------------------
-- B4. DATABASE FILENAMES AND PATHS — All Databases
--     Complete file information with growth and size details
--     Things to look at:
--       - Are data files and log files on different drives?
--       - Is everything on the C: drive?
--       - Is tempdb on dedicated drives?
--       - Is there only one tempdb data file?
--       - Are all of the tempdb data files the same size?
--       - Are there multiple data files for user databases?
--       - Is percent growth enabled for any files (which is bad)?
-----------------------------------------------------------------------
SELECT 
    DB_NAME([database_id])                        AS [Database Name], 
    [file_id], 
    [name], 
    physical_name, 
    [type_desc], 
    state_desc,
    is_percent_growth, 
    growth, 
    CONVERT(bigint, growth/128.0)                 AS [Growth in MB], 
    CONVERT(bigint, size/128.0)                   AS [Total Size in MB], 
    max_size
FROM sys.master_files WITH (NOLOCK)
ORDER BY DB_NAME([database_id]), [file_id] OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- B5. DATABASE SIZE SUMMARY — All Databases
--     Aggregated view of data file vs log file sizes
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                            AS DatabaseName,
    CAST(SUM(CASE WHEN type_desc = 'ROWS'
                  THEN size * 8.0 / 1024 ELSE 0 END)
         AS DECIMAL(18,2))                          AS DataFileMB,
    CAST(SUM(CASE WHEN type_desc = 'LOG'
                  THEN size * 8.0 / 1024 ELSE 0 END)
         AS DECIMAL(18,2))                          AS LogFileMB,
    CAST(SUM(size * 8.0 / 1024) AS DECIMAL(18,2))  AS TotalSizeMB
FROM sys.master_files
GROUP BY database_id
ORDER BY TotalSizeMB DESC;

-----------------------------------------------------------------------
-- B6. PERCENT-GROWTH FILE AUDIT
--     Percent growth is a bad practice — flag all instances
--     Includes fix commands to convert to fixed size growth
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    [name]                                        AS LogicalName,
    type_desc                                     AS FileType,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS CurrentSizeMB,
    CAST(growth AS VARCHAR(10)) + ' %'            AS GrowthSetting,
    'ALTER DATABASE ' + QUOTENAME(DB_NAME(database_id))
        + ' MODIFY FILE (NAME = ' + QUOTENAME([name])
        + ', FILEGROWTH = 256MB);'                AS FixCommand
FROM sys.master_files
WHERE is_percent_growth = 1
  AND growth > 0
ORDER BY DB_NAME(database_id), [name];

-----------------------------------------------------------------------
-- B7. AUTOGROWTH EVENTS (from default trace — on-prem only)
--     Shows recent file growth events. Frequent growths = bad sizing.
-----------------------------------------------------------------------
DECLARE @tracefile NVARCHAR(260);
SELECT @tracefile = REVERSE(
    SUBSTRING(REVERSE([path]),
        CHARINDEX(N'\', REVERSE([path])),
        260)) + N'log.trc'
FROM sys.traces
WHERE is_default = 1;

SELECT
    te.[name]                                    AS EventName,
    DB_NAME(t.DatabaseID)                        AS DatabaseName,
    t.FileName                                   AS LogicalFile,
    t.StartTime,
    t.EndTime,
    DATEDIFF(MILLISECOND, t.StartTime, t.EndTime) AS DurationMs,
    (t.IntegerData * 8.0 / 1024)                 AS GrowthMB
FROM sys.fn_trace_gettable(@tracefile, DEFAULT) t
    JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
WHERE te.[name] IN (
    'Data File Auto Grow',
    'Log File Auto Grow',
    'Data File Auto Shrink',
    'Log File Auto Shrink'
)
ORDER BY t.StartTime DESC;

-----------------------------------------------------------------------
-- B8. DATABASE FILE LOCATIONS (Simple)
--     Quick view of file locations for a specific database
-----------------------------------------------------------------------
SELECT 
    DB_NAME(database_id)                          AS DatabaseName,
    [file_id]                                     AS FileID,
    type_desc                                     AS FileType,
    [name]                                        AS LogicalName,
    physical_name                                 AS PhysicalPath
FROM sys.master_files
WHERE database_id = DB_ID()  -- Change database name as needed
ORDER BY type_desc, [file_id];

-----------------------------------------------------------------------
-- B9. FILE GROWTH SETTINGS CHECK
--     Comprehensive view of growth settings with max size details
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    type_desc                                     AS FileType,
    CASE
        WHEN is_percent_growth = 1 
            THEN CAST(growth AS VARCHAR(10)) + '%'
        ELSE CAST(CAST(growth AS BIGINT) * 8 / 1024 AS VARCHAR(20)) + ' MB'
    END                                           AS GrowthSetting,
    CASE
        WHEN max_size = -1 THEN 'Unlimited'
        WHEN max_size = 0 THEN 'No growth'
        WHEN type_desc = 'LOG' 
            THEN CAST(CAST(max_size AS BIGINT) * 8 / 1024 / 1024 / 1024 AS VARCHAR(20)) + ' TB'
        ELSE CAST(CAST(max_size AS BIGINT) * 8 / 1024 / 1024 AS VARCHAR(20)) + ' GB'
    END                                           AS MaxSize,
    is_percent_growth                             AS IsPercentGrowth
FROM sys.master_files
ORDER BY
    CASE
        WHEN database_id IN (1,2,3,4) THEN 0
        ELSE 1
    END,
    DB_NAME(database_id),
    type_desc;

-----------------------------------------------------------------------
-- B10. LARGEST DATABASES ON SPECIFIC DRIVE
--      Shows databases on a specific drive sorted by size
--      Useful for capacity planning and migration
-----------------------------------------------------------------------
SELECT 
    DB_NAME(database_id)                          AS DatabaseName,
    ROUND(SUM(size) * 8 / 1024, 0)               AS SizeMB
FROM sys.master_files
WHERE physical_name LIKE 'H:%'  -- Change drive letter as needed
  AND DB_NAME(database_id) NOT IN ('master','model','msdb')
GROUP BY DB_NAME(database_id) 
ORDER BY SizeMB DESC;

-----------------------------------------------------------------------
-- B11. LOGICAL FILE NAMES (Ordered by Type)
--      Lists files in the same order as SSMS GUI
--      Useful for scripting file operations
-----------------------------------------------------------------------
SELECT 
    DB_NAME(database_id)                          AS DatabaseName,
    file_id                                       AS FileID,
    type_desc                                     AS FileType,
    data_space_id                                 AS DataSpaceID,
    [name]                                        AS LogicalName,
    physical_name                                 AS PhysicalPath
FROM sys.master_files
WHERE database_id = DB_ID()  -- Change 'my_database_name' as needed
ORDER BY type_desc, 
         (CASE WHEN file_id = 1 THEN 0 ELSE 1 END), 
         [name];

-----------------------------------------------------------------------
-- B12. DATABASE SIZES (User Databases Only)
--      Shows total size of user databases excluding system databases
-----------------------------------------------------------------------
SELECT  
    d.[name]                                      AS DatabaseName,
    ROUND(SUM(mf.size) * 8 / 1024, 0)            AS SizeMB
FROM sys.master_files mf
    INNER JOIN sys.databases d ON d.database_id = mf.database_id
WHERE d.database_id > 4  -- Skip system databases
GROUP BY d.[name]
ORDER BY SizeMB DESC;

-----------------------------------------------------------------------
-- B13. SPACE USED BY FILES (Detailed)
--      Shows file utilization with free space and percentage used
--      Note: Uses legacy sysfiles view - works in current database only
-----------------------------------------------------------------------
SELECT
    FILEID                                        AS FileID,
    [NAME]                                        AS LogicalName,
    FILENAME                                      AS PhysicalPath,
    FILE_SIZE_MB,
    SPACE_USED_MB,
    CONVERT(INT, (SPACE_USED_MB / FILE_SIZE_MB) * 100) AS PercentUsed,
    FREE_SPACE_MB
FROM (
    SELECT
        a.FILEID,
        [FILE_SIZE_MB] = CONVERT(DECIMAL(15,2), ROUND(a.size/128.000, 2)),
        [SPACE_USED_MB] = CONVERT(DECIMAL(15,2), ROUND(FILEPROPERTY(a.[name],'SpaceUsed')/128.000, 2)),
        [FREE_SPACE_MB] = CONVERT(DECIMAL(15,2), ROUND((a.size - FILEPROPERTY(a.[name],'SpaceUsed'))/128.000, 2)),
        [NAME] = a.[NAME],
        FILENAME = a.FILENAME
    FROM dbo.sysfiles a
) x   
ORDER BY LogicalName;

-----------------------------------------------------------------------
-- B14. SPACE USED BY ALL DATABASES AND FILES
--      Creates temp table with detailed space information
--      Shows total, used, free space and percentage for all databases
-----------------------------------------------------------------------
CREATE TABLE #db_file_information( 
    fileid INTEGER,
    theFileGroup INTEGER,
    Total_Extents INTEGER,
    Used_Extents INTEGER,
    db VARCHAR(30),
    file_Path_name VARCHAR(300)
);

-- Get the size of the datafiles
INSERT INTO #db_file_information 
    (fileid, theFileGroup, Total_Extents, Used_Extents, db, file_Path_name)
EXEC sp_MSForEachDB 'Use ?; DBCC showfilestats';

-- Add computed columns
ALTER TABLE #db_file_information ADD PercentFree AS 
    ((Total_Extents - Used_Extents) * 100 / Total_extents);

ALTER TABLE #db_file_information ADD TotalSpace_MB AS 
    ((Total_Extents * 64) / 1024);

ALTER TABLE #db_file_information ADD UsedSpace_MB AS 
    ((Used_Extents * 64) / 1024);

ALTER TABLE #db_file_information ADD FreeSpace_MB AS 
    ((Total_Extents * 64) / 1024 - (Used_Extents * 64) / 1024);

-- Display results
SELECT * FROM #db_file_information
ORDER BY db, fileid;

-- Cleanup
DROP TABLE #db_file_information;

-----------------------------------------------------------------------
-- B15. LUN SPACE MONITORING (All Databases)
--      Shows space usage for all database files
--      Useful for identifying databases that are filling up
-----------------------------------------------------------------------
EXEC sp_MSForEachDB '
USE [?];
SELECT
    DB_NAME()                                    AS DatabaseName,
    [name]                                       AS LogicalName,
    size/128                                     AS SizeMB,
    FILEPROPERTY([name], ''SpaceUsed'')/128     AS SpaceUsedMB,
    size/128 - FILEPROPERTY([name], ''SpaceUsed'')/128 AS SpaceUnusedMB,
    CAST((FILEPROPERTY([name], ''SpaceUsed'')*100)/size AS FLOAT(1)) AS PercentFull,
    physical_name                                AS PhysicalPath
FROM sys.database_files
ORDER BY SpaceUnusedMB DESC;
';

-----------------------------------------------------------------------
-- B16. LUN SPACE MONITORING (Specific LUNs)
--      Monitors space on specific LUN paths
--      Change the LIKE pattern to match your LUN naming convention
-----------------------------------------------------------------------
EXEC sp_MSForEachDB '
USE [?];
SELECT
    DB_NAME()                                    AS DatabaseName,
    [name]                                       AS LogicalName,
    size/128                                     AS SizeMB,
    FILEPROPERTY([name], ''SpaceUsed'')/128     AS SpaceUsedMB,
    size/128 - FILEPROPERTY([name], ''SpaceUsed'')/128 AS SpaceUnusedMB,
    CAST((FILEPROPERTY([name], ''SpaceUsed'')*100)/size AS FLOAT(1)) AS PercentFull,
    physical_name                                AS PhysicalPath
FROM sys.database_files
WHERE physical_name LIKE ''O:\server_userdbs_oltp_0[1234]%''
ORDER BY SpaceUnusedMB DESC;
';

-----------------------------------------------------------------------
-- B17. TABLE STORAGE ANALYSIS
--      Shows row counts and space usage for all user tables
--      Useful for identifying large tables and planning maintenance
-----------------------------------------------------------------------
SELECT
    t.[NAME]                                      AS TableName,
    SUM(p.rows)                                   AS RowCounts,
    SUM(a.total_pages) * 8                        AS TotalSpaceKB,
    SUM(a.used_pages) * 8                         AS UsedSpaceKB,
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8  AS UnusedSpaceKB
FROM sys.tables t
    INNER JOIN sys.indexes i ON t.OBJECT_ID = i.object_id
    INNER JOIN sys.partitions p ON i.object_id = p.OBJECT_ID 
        AND i.index_id = p.index_id
    INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.[NAME] NOT LIKE 'dt%'
  AND t.is_ms_shipped = 0
  AND i.OBJECT_ID > 255
GROUP BY t.[Name]
ORDER BY UsedSpaceKB DESC;

-----------------------------------------------------------------------
-- B18. ALLOCATION UNITS BY FILE AND PARTITION
--      Detailed view of how tables are allocated across files
--      Useful for understanding file growth patterns
-----------------------------------------------------------------------
SELECT
    OBJECT_NAME(p.object_id)                      AS TableName,
    u.type_desc                                   AS AllocationUnitType,
    f.file_id                                     AS FileID,
    f.[name]                                      AS LogicalFileName,
    f.physical_name                               AS PhysicalPath,
    f.size                                        AS FileSize,
    f.max_size                                    AS MaxSize,
    f.growth                                      AS Growth,
    u.total_pages                                 AS TotalPages,
    u.used_pages                                  AS UsedPages,
    u.data_pages                                  AS DataPages,
    p.partition_id                                AS PartitionID,
    p.rows                                        AS [Rows]
FROM sys.allocation_units u
    JOIN sys.database_files f ON u.data_space_id = f.data_space_id
    JOIN sys.partitions p ON u.container_id = p.hobt_id
WHERE u.[type] IN (1, 3)  -- IN_ROW_DATA and LOB_DATA
ORDER BY p.rows DESC;


/*==============================================================================
  SECTION C: TEMPDB FILE MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- C1. TEMPDB DATA FILES COUNT (from Error Log)
--     Shows the number of data files in the tempdb database
--     
--     Best Practice: 4-8 data files that are all the same size
--     All tempdb data files should have the same initial size and 
--     autogrowth settings
--     
--     Note: This query will return no results if your error log has 
--     been recycled since the instance was last started
--     
--     KB3170020 - Informational messages added for tempdb configuration 
--     in the SQL Server error log in SQL Server 2012 and 2014
--     https://bit.ly/3IsR8jh
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'The tempdb database has';

-----------------------------------------------------------------------
-- C2. TEMPDB SPACE USAGE BY OBJECT TYPE
--     Shows space used by internal objects, user objects, and version store
--     Run weekly to monitor tempdb growth patterns
-----------------------------------------------------------------------
SELECT
    SUM(internal_object_reserved_page_count) * 8  AS InternalObjectsKB,
    SUM(unallocated_extent_page_count) * 8        AS FreeSpaceKB,
    SUM(version_store_reserved_page_count) * 8    AS VersionStoreKB,
    SUM(user_object_reserved_page_count) * 8      AS UserObjectsKB
FROM sys.dm_db_file_space_usage
WHERE database_id = 2;


/*==============================================================================
  SECTION D: TRANSACTION LOG MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- D1. TRANSACTION LOG SPACE USAGE (DBCC Method)
--     Classic method to show log space usage for all databases
-----------------------------------------------------------------------
DBCC SQLPERF(LOGSPACE);

-----------------------------------------------------------------------
-- D2. TRANSACTION LOG SPACE USAGE (DMV Method)
--     More detailed log space information with status alerts
--     Shows information for the current database only
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                              AS DatabaseName,
    CAST(total_log_size_in_bytes / 1048576.0
         AS DECIMAL(18,2))                            AS TotalLogSizeMB,
    CAST(used_log_space_in_bytes / 1048576.0
         AS DECIMAL(18,2))                            AS UsedLogSpaceMB,
    CAST(used_log_space_in_percent AS DECIMAL(5,2))   AS UsedLogPct,
    CASE
        WHEN used_log_space_in_percent > 80
            THEN '*** HIGH USAGE ***'
        WHEN used_log_space_in_percent > 60
            THEN '* Warning *'
        ELSE 'OK'
    END                                               AS [Status]
FROM sys.dm_db_log_space_usage;

-----------------------------------------------------------------------
-- D3. LOG REUSE WAIT REASON (All Databases)
--     Shows what is preventing the log from being reused.
--     Common reasons: NOTHING, LOG_BACKUP, ACTIVE_TRANSACTION, REPLICATION
-----------------------------------------------------------------------
SELECT
    [name]                 AS DatabaseName,
    recovery_model_desc    AS RecoveryModel,
    log_reuse_wait_desc    AS LogReuseWaitReason,
    state_desc             AS DatabaseState
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY
    CASE log_reuse_wait_desc
        WHEN 'NOTHING'        THEN 99
        WHEN 'LOG_BACKUP'     THEN 1
        WHEN 'ACTIVE_TRANSACTION' THEN 2
        WHEN 'REPLICATION'    THEN 3
        ELSE 10
    END;

-----------------------------------------------------------------------
-- D4. VLF COUNT (Current Database)
--     High VLF counts (> 1000) cause slow recovery and log operations
--     Fix: shrink log, then grow in large fixed increments
--     Requires SQL Server 2016 SP2+ / 2017+
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id) AS DatabaseName,
    COUNT(*)             AS VLFCount,
    CASE
        WHEN COUNT(*) > 1000 THEN '*** TOO HIGH ***'
        WHEN COUNT(*) > 500  THEN '* Warning *'
        ELSE 'OK'
    END                  AS [Status]
FROM sys.dm_db_log_info(DB_ID())
GROUP BY database_id;

-----------------------------------------------------------------------
-- D5. VLF COUNT (All Databases)
--     Shows VLF count for all online databases
--     Requires SQL Server 2017+
-----------------------------------------------------------------------
SELECT
    DB_NAME(li.database_id) AS DatabaseName,
    COUNT(*)                AS VLFCount
FROM sys.databases d
    CROSS APPLY sys.dm_db_log_info(d.database_id) li
WHERE d.state_desc = 'ONLINE'
GROUP BY li.database_id
ORDER BY COUNT(*) DESC;
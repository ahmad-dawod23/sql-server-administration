/*==============================================================================
  DISK SPACE, FILE MANAGEMENT & TRANSACTION LOG HEALTH
  
  Purpose : Monitor volume free space, database file sizes, autogrowth
            events, VLF counts, and log space usage.
  Safety  : Everything here is read-only diagnostic output - nothing
            modifies a database. Two things to be aware of:
              - B14 creates/drops a #temp table and loops databases.
              - B6 GENERATES ALTER DATABASE statements as text; it does
                not execute them. Review the output before running it.
  Usage   : Batches are separated by GO - run one query at a time.
  Gotchas : * sys.master_files reports tempdb's configured (restart)
              size, not its current size - use Section C for live tempdb.
            * FILEPROPERTY(), sys.database_files and
              sys.dm_db_file_space_usage are scoped to the CURRENT
              database and return NULL/nothing for other databases.
  
  TABLE OF CONTENTS:
  ==================
  SECTION A: DISK & VOLUME SPACE MONITORING
    A1. Volume Free Space (All Database Files)
    A2. Volumes / Mount Points Used by Instance
    A3. Fixed Drives Enumeration (SQL Server 2019+)
  
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
    B13. Space Used by Files (Detailed, Current Database)
    B14. Space Used by All Databases and Files
    B15. File Space by Volume / LUN
    B16. Table Storage Analysis
    B17. Allocation Units by Filegroup and Partition
    B18. Filegroup Free Space (Current Database)
  
  SECTION C: TEMPDB FILE MANAGEMENT
    C1. TempDB Data Files Count (from Error Log)
    C2. TempDB Space Usage by Object Type
  
  SECTION D: TRANSACTION LOG MANAGEMENT
    D1. Transaction Log Space Usage (DBCC Method)
    D2. Transaction Log Space Usage (DMV Method)
    D3. Log Reuse Wait Reason (All Databases)
    D4. VLF Count (Current Database)
    D5. VLF Count (All Databases)
    D6. Multiple Transaction Log Files Check
    D7. Transaction Log Statistics (SQL Server 2016 SP2+ / 2017+)
==============================================================================*/
GO


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
    CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) AS DECIMAL(5,2)) AS FreePct,
    vs.supports_compression                      AS SupportsCompression,
    vs.is_compressed                             AS IsCompressed,
    vs.supports_sparse_files                     AS SupportsSparseFiles,
    vs.supports_alternate_streams                AS SupportsAlternateStreams,
    CASE
        WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) < 10
            THEN '*** LOW SPACE ***'
        WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) < 20
            THEN '* Warning *'
        ELSE 'OK'
    END                                          AS [Status]
FROM sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs
ORDER BY FreePct ASC;
GO

-----------------------------------------------------------------------
-- A2. VOLUMES / MOUNT POINTS USED BY INSTANCE
--     Lists the distinct volumes (including mount points) that host
--     database files.
--     NOTE: parsing physical_name with SUBSTRING/CHARINDEX returns a
--     folder rather than a volume as soon as files live more than one
--     level deep, so take the mount point from sys.dm_os_volume_stats.
-----------------------------------------------------------------------
SELECT DISTINCT
    vs.volume_mount_point   AS VolumeMountPoint,
    vs.logical_volume_name  AS VolumeName,
    vs.file_system_type     AS FileSystemType
FROM sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs
ORDER BY vs.volume_mount_point;
GO

-----------------------------------------------------------------------
-- A3. FIXED DRIVES ENUMERATION (SQL Server 2019+)
--     Shows all fixed drives on the server (not limited to SQL files).
-----------------------------------------------------------------------
SELECT *
FROM sys.dm_os_enumerate_fixed_drives;
GO


/*==============================================================================
  SECTION B: DATABASE FILE MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- OVERVIEW: FILE PLACEMENT & GROWTH BEST PRACTICES
-----------------------------------------------------------------------
-- * Separate data (.mdf/.ndf) and log (.ldf) files onto different
--   physical disk arrays/volumes. Log writes are sequential while data
--   access is largely random; keeping them apart avoids one workload
--   competing with the other for the same spindles/IOPS.
-- * TempDB is a shared, write-heavy instance resource - place it on
--   the fastest available storage, separate from user databases (see
--   performance-tempdb.sql, Section 1, for file-count/sizing checks).
-- * Pre-size data/log files to fit expected growth instead of relying
--   on autogrowth for day-to-day operation. If autogrow is needed, use
--   a fixed MB increment (64MB+) rather than a percentage - see B6
--   (percent-growth audit) and B9 (growth settings check) below.
-- * Leave AUTO_SHRINK OFF. Shrinking fragments the file system and is
--   CPU/IO-intensive; it very rarely provides a lasting benefit.
-- * Grant the SQL Server service account "Perform Volume Maintenance
--   Tasks" (Instant File Initialization) so data file growth/restores
--   don't have to zero-fill new space - this can dramatically speed up
--   both operations. Log files can never use IFI (always zero-filled).
--   Check via sys.dm_server_services.instant_file_initialization_enabled
--   (see info-and-best-practices-queries.sql, Section 1.2).
-- * A database only ever writes to ONE transaction log file at a time,
--   so additional log files add no throughput - see D6.
-- * sys.master_files shows tempdb's configured size (what it will be
--   after the next restart), NOT its current size. Use Section C, or
--   sys.database_files from inside tempdb, for live tempdb sizing.
-----------------------------------------------------------------------

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
        WHEN mf.max_size = -1         THEN 'Unlimited'
        WHEN mf.max_size = 0          THEN 'No growth'
        WHEN mf.max_size = 2147483647 THEN 'Unlimited'  -- LOG file sentinel
        WHEN mf.max_size = 268435456  THEN 'Unlimited'  -- FILESTREAM sentinel
        ELSE CAST(CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
    END                                           AS MaxSize,
    mf.is_percent_growth                          AS IsPercentGrowth
FROM sys.master_files mf
WHERE mf.database_id = DB_ID()  -- do NOT remove: FILEPROPERTY only resolves
                                -- names in the CURRENT database and returns
                                -- NULL for every other database. Use B14 for
                                -- used/free space across all databases.
ORDER BY mf.type_desc, mf.[name];
GO

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
GO

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
GO

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
GO

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
GO

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
GO

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
GO

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
GO

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
        WHEN max_size = -1         THEN 'Unlimited'
        WHEN max_size = 0          THEN 'No growth'
        WHEN max_size = 2147483647 THEN 'Unlimited'  -- LOG file sentinel
        WHEN max_size = 268435456  THEN 'Unlimited'  -- FILESTREAM sentinel
        ELSE CAST(CAST(max_size AS BIGINT) * 8 / 1024 AS VARCHAR(20)) + ' MB'
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
GO

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
GO

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
GO

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
GO

-----------------------------------------------------------------------
-- B13. SPACE USED BY FILES (Detailed) — Current Database
--      File utilisation with free space and percent used.
--      Uses sys.database_files; dbo.sysfiles is a deprecated backward-
--      compatibility view and should not be used in new scripts.
-----------------------------------------------------------------------
SELECT
    df.[file_id]                                  AS FileID,
    df.[name]                                     AS LogicalName,
    df.type_desc                                  AS FileType,
    df.physical_name                              AS PhysicalPath,
    CAST(df.size / 128.0 AS DECIMAL(15,2))        AS FileSizeMB,
    CAST(FILEPROPERTY(df.[name], 'SpaceUsed') / 128.0
         AS DECIMAL(15,2))                        AS SpaceUsedMB,
    CAST((df.size - FILEPROPERTY(df.[name], 'SpaceUsed')) / 128.0
         AS DECIMAL(15,2))                        AS FreeSpaceMB,
    CAST(100.0 * FILEPROPERTY(df.[name], 'SpaceUsed') / NULLIF(df.size, 0)
         AS DECIMAL(5,2))                         AS PercentUsed
FROM sys.database_files df
WHERE df.type_desc IN ('ROWS', 'LOG')
ORDER BY df.type_desc, df.[name];
GO

-----------------------------------------------------------------------
-- B14. SPACE USED BY ALL DATABASES AND FILES
--      Walks every accessible ONLINE database and captures per-file
--      size / used / free.
--      Replaces the old "sp_MSForEachDB + DBCC SHOWFILESTATS" version,
--      which returned no database name at all (the column labelled 'db'
--      was actually the logical FILE name), silently omitted log files,
--      truncated logical names longer than 30 chars, and divided by
--      zero on empty files.
--      Note: sp_MSForEachDB is undocumented, skips databases whose name
--      contains certain characters, and errors on OFFLINE / RESTORING
--      databases — hence the explicit cursor below.
-----------------------------------------------------------------------
IF OBJECT_ID('tempdb..#db_file_information') IS NOT NULL
    DROP TABLE #db_file_information;

CREATE TABLE #db_file_information (
    DatabaseName  sysname,
    FileID        INT,
    LogicalName   sysname,
    FileType      NVARCHAR(60),
    PhysicalPath  NVARCHAR(520),
    FileSizeMB    DECIMAL(18,2),
    SpaceUsedMB   DECIMAL(18,2)
);

DECLARE @dbname sysname, @sql NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT [name]
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND HAS_DBACCESS([name]) = 1;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- QUOTENAME + a name sourced only from sys.databases keeps this safe
    SET @sql = N'USE ' + QUOTENAME(@dbname) + N';
        SELECT DB_NAME(), [file_id], [name], type_desc, physical_name,
               CAST(size / 128.0 AS DECIMAL(18,2)),
               CAST(FILEPROPERTY([name], ''SpaceUsed'') / 128.0 AS DECIMAL(18,2))
        FROM sys.database_files
        WHERE type_desc IN (''ROWS'', ''LOG'');';

    BEGIN TRY
        INSERT INTO #db_file_information
            (DatabaseName, FileID, LogicalName, FileType,
             PhysicalPath, FileSizeMB, SpaceUsedMB)
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'Skipped ' + QUOTENAME(@dbname) + ': ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM db_cur INTO @dbname;
END

CLOSE db_cur;
DEALLOCATE db_cur;

SELECT
    DatabaseName,
    FileID,
    LogicalName,
    FileType,
    PhysicalPath,
    FileSizeMB,
    SpaceUsedMB,
    FileSizeMB - SpaceUsedMB                      AS FreeSpaceMB,
    CAST(100.0 * SpaceUsedMB / NULLIF(FileSizeMB, 0)
         AS DECIMAL(5,2))                         AS PercentUsed
FROM #db_file_information
ORDER BY DatabaseName, FileType, FileID;

DROP TABLE #db_file_information;
GO

-----------------------------------------------------------------------
-- B15. FILE SPACE BY VOLUME / LUN
--      Every database file grouped against the volume that hosts it,
--      with that volume's free space — shows which files are driving
--      consumption on a given LUN.
--      Set @PathFilter to target specific LUNs (NULL = all volumes).
--      Replaces the two near-identical sp_MSForEachDB queries that
--      used integer division for PercentFull (always rounded down)
--      and divided by zero on 0-page files.
-----------------------------------------------------------------------
DECLARE @PathFilter NVARCHAR(260) = NULL;
-- e.g. N'O:\server_userdbs_oltp_0[1234]%'

SELECT
    vs.volume_mount_point                          AS VolumeMountPoint,
    DB_NAME(mf.database_id)                        AS DatabaseName,
    mf.[name]                                      AS LogicalName,
    mf.type_desc                                   AS FileType,
    mf.physical_name                               AS PhysicalPath,
    CAST(mf.size / 128.0 AS DECIMAL(18,2))         AS FileSizeMB,
    CAST(vs.total_bytes / 1073741824.0
         AS DECIMAL(18,2))                         AS VolumeTotalGB,
    CAST(vs.available_bytes / 1073741824.0
         AS DECIMAL(18,2))                         AS VolumeFreeGB,
    CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0)
         AS DECIMAL(5,2))                          AS VolumeFreePct
FROM sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs
WHERE @PathFilter IS NULL
   OR mf.physical_name LIKE @PathFilter
ORDER BY VolumeFreePct ASC, FileSizeMB DESC;
GO

-----------------------------------------------------------------------
-- B16. TABLE STORAGE ANALYSIS — Current Database
--      Row counts and space usage for all user tables.
--      Row counts are taken from the heap / clustered index only
--      (index_id 0 or 1). Summing p.rows across every index — as the
--      widely copied version of this query does — multiplies the row
--      count by the number of indexes on the table.
--      Schema is included so same-named tables in different schemas
--      are not merged.
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(t.schema_id)                      AS SchemaName,
    t.[name]                                      AS TableName,
    SUM(CASE WHEN i.index_id IN (0, 1)
             THEN p.[rows] ELSE 0 END)            AS [RowCount],
    SUM(a.total_pages) * 8                        AS TotalSpaceKB,
    SUM(a.used_pages) * 8                         AS UsedSpaceKB,
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8  AS UnusedSpaceKB
FROM sys.tables t
    INNER JOIN sys.indexes i ON t.[object_id] = i.[object_id]
    INNER JOIN sys.partitions p ON i.[object_id] = p.[object_id]
        AND i.index_id = p.index_id
    INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0
GROUP BY SCHEMA_NAME(t.schema_id), t.[name]
ORDER BY UsedSpaceKB DESC;
GO

-----------------------------------------------------------------------
-- B17. ALLOCATION UNITS BY FILEGROUP AND PARTITION — Current Database
--      IMPORTANT: sys.allocation_units.data_space_id is a FILEGROUP id,
--      not a file id. Joining it to sys.database_files.data_space_id
--      (as the common version of this query does) fans every allocation
--      unit out across every file in the filegroup, so the per-file
--      attribution is fictional. Report at filegroup level instead and
--      use B18 for filegroup free space.
--      Allocation unit types: 1 = IN_ROW_DATA, 2 = LOB_DATA,
--      3 = ROW_OVERFLOW_DATA. container_id maps to hobt_id for types
--      1 and 3, and to partition_id for type 2.
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(o.schema_id)                      AS SchemaName,
    OBJECT_NAME(p.[object_id])                    AS TableName,
    fg.[name]                                     AS FileGroupName,
    u.type_desc                                   AS AllocationUnitType,
    p.partition_number                            AS PartitionNumber,
    p.partition_id                                AS PartitionID,
    u.total_pages                                 AS TotalPages,
    u.used_pages                                  AS UsedPages,
    u.data_pages                                  AS DataPages,
    CAST(u.total_pages * 8.0 / 1024
         AS DECIMAL(18,2))                        AS TotalMB,
    p.[rows]                                      AS [Rows]
FROM sys.allocation_units u
    JOIN sys.partitions p
        ON (u.[type] IN (1, 3) AND u.container_id = p.hobt_id)
        OR (u.[type] = 2       AND u.container_id = p.partition_id)
    JOIN sys.objects o ON p.[object_id] = o.[object_id]
    LEFT JOIN sys.filegroups fg ON u.data_space_id = fg.data_space_id
WHERE o.is_ms_shipped = 0
ORDER BY u.total_pages DESC;
GO

-----------------------------------------------------------------------
-- B18. FILEGROUP FREE SPACE — Current Database
--      Space is allocated per FILEGROUP, not per volume. A filegroup
--      can be effectively full (autogrowth capped, or read-only) while
--      the underlying volume still has plenty of space, so check both
--      this and A1.
-----------------------------------------------------------------------
SELECT
    fg.[name]                                     AS FileGroupName,
    fg.type_desc                                  AS FileGroupType,
    fg.is_default                                 AS IsDefault,
    fg.is_read_only                               AS IsReadOnly,
    COUNT(*)                                      AS FileCount,
    CAST(SUM(df.size / 128.0) AS DECIMAL(18,2))   AS TotalMB,
    CAST(SUM(FILEPROPERTY(df.[name], 'SpaceUsed') / 128.0)
         AS DECIMAL(18,2))                        AS UsedMB,
    CAST(SUM((df.size - FILEPROPERTY(df.[name], 'SpaceUsed')) / 128.0)
         AS DECIMAL(18,2))                        AS FreeMB,
    CAST(100.0 * SUM(CAST(FILEPROPERTY(df.[name], 'SpaceUsed') AS BIGINT))
         / NULLIF(SUM(CAST(df.size AS BIGINT)), 0)
         AS DECIMAL(5,2))                         AS PercentUsed
FROM sys.filegroups fg
    JOIN sys.database_files df ON fg.data_space_id = df.data_space_id
GROUP BY fg.[name], fg.type_desc, fg.is_default, fg.is_read_only
ORDER BY PercentUsed DESC;
GO


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
GO

-----------------------------------------------------------------------
-- C2. TEMPDB SPACE USAGE BY OBJECT TYPE
--     Shows space used by internal objects, user objects, and version store
--     Run weekly to monitor tempdb growth patterns
--
--     IMPORTANT: sys.dm_db_file_space_usage only returns rows for the
--     CURRENT database, so "WHERE database_id = 2" returns nothing
--     unless you are already connected to tempdb. Running it through
--     tempdb.sys.sp_executesql executes it in tempdb context without
--     changing your session's database.
-----------------------------------------------------------------------
EXEC tempdb.sys.sp_executesql N'
SELECT
    SUM(internal_object_reserved_page_count) * 8  AS InternalObjectsKB,
    SUM(unallocated_extent_page_count) * 8        AS FreeSpaceKB,
    SUM(version_store_reserved_page_count) * 8    AS VersionStoreKB,
    SUM(user_object_reserved_page_count) * 8      AS UserObjectsKB
FROM sys.dm_db_file_space_usage;';
GO


/*==============================================================================
  SECTION D: TRANSACTION LOG MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- D1. TRANSACTION LOG SPACE USAGE (DBCC Method)
--     Classic method to show log space usage for all databases
-----------------------------------------------------------------------
DBCC SQLPERF(LOGSPACE);
GO

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
GO

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
GO

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
GO

-----------------------------------------------------------------------
-- D5. VLF COUNT (All Databases)
--     Shows VLF count for all online databases
--     Requires SQL Server 2016 SP2+ / 2017+
--     HAS_DBACCESS filters out databases the caller cannot open (e.g.
--     non-readable AG secondaries), which would otherwise error.
-----------------------------------------------------------------------
SELECT
    DB_NAME(li.database_id) AS DatabaseName,
    COUNT(*)                AS VLFCount,
    CASE
        WHEN COUNT(*) > 1000 THEN '*** TOO HIGH ***'
        WHEN COUNT(*) > 500  THEN '* Warning *'
        ELSE 'OK'
    END                     AS [Status]
FROM sys.databases d
    CROSS APPLY sys.dm_db_log_info(d.database_id) li
WHERE d.state_desc = 'ONLINE'
  AND HAS_DBACCESS(d.[name]) = 1
GROUP BY li.database_id
ORDER BY COUNT(*) DESC;
GO

-----------------------------------------------------------------------
-- D6. MULTIPLE TRANSACTION LOG FILES CHECK
--     SQL Server writes to only ONE log file at a time, so extra log
--     files add no throughput - they just complicate management,
--     restores and log-shipping. Anything above 1 is worth reviewing
--     (a second file is only ever a temporary fix for a full volume).
-----------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id)                          AS DatabaseName,
    COUNT(*)                                         AS LogFileCount,
    CAST(SUM(mf.size * 8.0 / 1024) AS DECIMAL(18,2)) AS TotalLogMB,
    CASE
        WHEN COUNT(*) > 1 THEN '*** EXTRA LOG FILES - REVIEW ***'
        ELSE 'OK'
    END                                              AS [Status]
FROM sys.master_files mf
WHERE mf.type_desc = 'LOG'
GROUP BY mf.database_id
ORDER BY COUNT(*) DESC, DatabaseName;
GO

-----------------------------------------------------------------------
-- D7. TRANSACTION LOG STATISTICS (SQL Server 2016 SP2+ / 2017+)
--     Growth/shrink counts, active vs total log size, size still to be
--     backed up, and the recovery size. Complements the VLF counts in
--     D4/D5: repeated growths + high VLF count = badly sized log.
-----------------------------------------------------------------------
SELECT
    DB_NAME(d.database_id)                                 AS DatabaseName,
    d.recovery_model_desc                                  AS RecoveryModel,
    CAST(ls.total_log_size_mb AS DECIMAL(18,2))            AS TotalLogSizeMB,
    CAST(ls.active_log_size_mb AS DECIMAL(18,2))           AS ActiveLogSizeMB,
    CAST(ls.log_since_last_log_backup_mb AS DECIMAL(18,2)) AS SinceLastLogBackupMB,
    CAST(ls.log_recovery_size_mb AS DECIMAL(18,2))         AS RecoverySizeMB,
    ls.total_vlf_count                                     AS VLFCount,
    ls.log_growth_count                                    AS GrowthCount,
    ls.log_shrink_count                                    AS ShrinkCount,
    ls.log_truncation_holdup_reason                        AS TruncationHoldupReason
FROM sys.databases d
    CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = 'ONLINE'
  AND HAS_DBACCESS(d.[name]) = 1
ORDER BY ls.total_log_size_mb DESC;
GO

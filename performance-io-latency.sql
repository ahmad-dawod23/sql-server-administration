-----------------------------------------------------------------------
-- I/O LATENCY ANALYSIS (ON-PREM & MI)
-- Purpose : Measure read/write latency per database file using
--           sys.dm_io_virtual_file_stats. Identifies slow storage
--           that may be causing PAGEIOLATCH or WRITELOG waits.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

-----------------------------------------------------------------------
-- OVERVIEW: WHAT DOES "BUFFER I/O BOUND" MEAN?
-- Purpose : Background/concepts for interpreting the queries below.
-----------------------------------------------------------------------
-- A query that is "mostly bound by buffer I/O" is one whose primary
-- bottleneck is physical I/O — reading data pages from disk into the
-- buffer pool — rather than CPU.
--
-- Logical reads vs. physical reads:
--   * Logical reads  = pages read from the buffer pool (memory).
--     Cheap individually, but a very high count still costs CPU time.
--   * Physical reads = pages that must be pulled from disk because
--     they are not already cached. Expensive — disk is typically the
--     slowest resource in the stack, and this is what the queries in
--     this script measure directly (latency, stalls, IOPS).
--
-- Primary indicator: PAGEIOLATCH_* / WRITELOG waits
--   A worker thread is suspended waiting for a data page to be read
--   from (PAGEIOLATCH_SH/EX) or a log record flushed to (WRITELOG)
--   disk. A high volume of these waits in sys.dm_os_wait_stats is the
--   clearest sign of a buffer-I/O-bound workload — see
--   performance-wait-stats.sql for instance-wide wait analysis, and
--   Section 10 below to drill down to the specific table/index.
--
-- Root causes (roughly in order of likelihood):
--   1. Memory pressure — buffer pool too small, Page Life Expectancy
--      too low, or buffer cache hit ratio below ~90%, so pages get
--      flushed and must be re-read from disk constantly.
--      -> See performance-buffer-pool-and-memory-analysis.sql
--         (Section 5 = PLE, Section 1.4 = hit ratio).
--   2. Inefficient query/index design — table/index scans, missing or
--      fragmented indexes, and key/RID lookups all force SQL Server
--      to touch (and potentially fault in) far more pages than
--      necessary.
--      -> See Sections 10-12 below and
--         performance-index-and-statistics-maintenance.sql.
--   3. Slow or saturated storage subsystem — high disk latency or
--      queueing means every physical read/write simply takes longer.
--      -> Measured directly by the file-, drive-, and IOPS-level
--         queries in Sections 2, 3, 5, 7, and 9 below.
--
-- Resolution strategy:
--   Strategy          | Action
--   ------------------+---------------------------------------------
--   Increase cache     | Add RAM to grow the buffer pool so fewer
--                       | pages need to be re-read from disk.
--   Optimize queries    | Add/tighten WHERE clauses; avoid returning
--                       | more rows/columns than needed.
--   Improve indexing    | Add indexes so seeks replace scans; use
--                       | covering indexes to avoid key/RID lookups.
--   Upgrade storage      | Faster disks/IOPS, especially for the
--                       | random I/O patterns typical of OLTP.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. PENDING I/O REQUESTS (live snapshot)
--    Shows I/O requests currently in flight. Useful during an active
--    I/O performance incident.
--
--    What to look for:
--      Many pending requests = storage subsystem can't keep up
--      Long io_pending_ms_ticks = individual I/Os are slow
-----------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id)                          AS DatabaseName,
    mf.[name]                                        AS LogicalFileName,
    mf.physical_name                                 AS PhysicalPath,
    mf.type_desc                                     AS FileType,
    pior.io_type,
    pior.io_pending_ms_ticks                         AS PendingMs,
    pior.io_pending
FROM sys.dm_io_pending_io_requests AS pior
INNER JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
    ON pior.io_handle = fs.file_handle
INNER JOIN sys.master_files AS mf
    ON fs.database_id = mf.database_id
    AND fs.[file_id] = mf.[file_id]
ORDER BY pior.io_pending_ms_ticks DESC
OPTION (RECOMPILE);



-----------------------------------------------------------------------
-- 2. I/O LATENCY — DATA FILES ONLY (sorted by read latency)
--    Focused view for diagnosing PAGEIOLATCH waits.
--
--    What to look for:
--      Avg read latency > 20ms on data files = storage bottleneck
--      High read counts + high latency = hot files that need faster storage
-----------------------------------------------------------------------
SELECT
    DB_NAME(fs.database_id)                          AS DatabaseName,
    mf.[name]                                        AS LogicalFileName,
    mf.physical_name                                 AS PhysicalPath,
    fs.num_of_reads                                  AS TotalReads,
    CASE
        WHEN fs.num_of_reads = 0 THEN 0
        ELSE CAST(fs.io_stall_read_ms * 1.0 / fs.num_of_reads AS DECIMAL(16,2))
    END                                              AS AvgReadLatencyMs,
    CAST(fs.num_of_bytes_read / 1048576.0 AS DECIMAL(18,2)) AS TotalReadMB,
    CASE
        WHEN fs.num_of_reads = 0 THEN 'N/A — no reads'
        WHEN (fs.io_stall_read_ms * 1.0 / fs.num_of_reads) < 5    THEN 'Excellent (<5ms)'
        WHEN (fs.io_stall_read_ms * 1.0 / fs.num_of_reads) < 10   THEN 'Good (5-10ms)'
        WHEN (fs.io_stall_read_ms * 1.0 / fs.num_of_reads) < 20   THEN 'Acceptable (10-20ms)'
        WHEN (fs.io_stall_read_ms * 1.0 / fs.num_of_reads) < 50   THEN '* Slow (20-50ms) *'
        ELSE '*** VERY SLOW (>50ms) — investigate storage ***'
    END                                              AS ReadPerformance
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
INNER JOIN sys.master_files AS mf
    ON fs.database_id = mf.database_id
    AND fs.[file_id] = mf.[file_id]
WHERE mf.type_desc = 'ROWS'
  AND fs.num_of_reads > 0
ORDER BY
    CASE WHEN fs.num_of_reads = 0 THEN 0
         ELSE fs.io_stall_read_ms * 1.0 / fs.num_of_reads
    END DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 3. I/O LATENCY — LOG FILES ONLY (sorted by write latency)
--    Focused view for diagnosing WRITELOG waits.
--
--    What to look for:
--      Log write latency > 2ms on SSD is concerning
--      Log write latency > 5ms on spinning disk needs attention
--      Very high latency (>15ms) directly impacts transaction throughput
-----------------------------------------------------------------------
SELECT
    DB_NAME(fs.database_id)                          AS DatabaseName,
    mf.[name]                                        AS LogicalFileName,
    mf.physical_name                                 AS PhysicalPath,
    fs.num_of_writes                                 AS TotalWrites,
    CASE
        WHEN fs.num_of_writes = 0 THEN 0
        ELSE CAST(fs.io_stall_write_ms * 1.0 / fs.num_of_writes AS DECIMAL(16,2))
    END                                              AS AvgWriteLatencyMs,
    fs.num_of_reads                                  AS TotalReads,
    CASE
        WHEN fs.num_of_reads = 0 THEN 0
        ELSE CAST(fs.io_stall_read_ms * 1.0 / fs.num_of_reads AS DECIMAL(16,2))
    END                                              AS AvgReadLatencyMs,
    CAST(fs.num_of_bytes_written / 1048576.0 AS DECIMAL(18,2)) AS TotalWriteMB,
    CASE
        WHEN fs.num_of_writes = 0 THEN 'N/A — no writes'
        WHEN (fs.io_stall_write_ms * 1.0 / fs.num_of_writes) < 2    THEN 'Excellent (<2ms)'
        WHEN (fs.io_stall_write_ms * 1.0 / fs.num_of_writes) < 5    THEN 'Good (2-5ms)'
        WHEN (fs.io_stall_write_ms * 1.0 / fs.num_of_writes) < 15   THEN '* Moderate (5-15ms) — review disk config *'
        ELSE '*** HIGH LATENCY (>15ms) — impacting transaction throughput ***'
    END                                              AS LogWritePerformance
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
INNER JOIN sys.master_files AS mf
    ON fs.database_id = mf.database_id
    AND fs.[file_id] = mf.[file_id]
WHERE mf.type_desc = 'LOG'
  AND fs.num_of_writes > 0
ORDER BY
    CASE WHEN fs.num_of_writes = 0 THEN 0
         ELSE fs.io_stall_write_ms * 1.0 / fs.num_of_writes
    END DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 4. I/O WARNING DETECTION FROM ERROR LOG
--    Look for I/O requests taking longer than 15 seconds in error logs.
--    These warnings indicate severe storage performance issues that 
--    are directly impacting the SQL Server instance.
-----------------------------------------------------------------------
DROP TABLE IF EXISTS #IOWarningResults;
CREATE TABLE #IOWarningResults(
    LogDate DATETIME,
    ProcessInfo NVARCHAR(50),
    LogText NVARCHAR(MAX)
);

INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 1, 1, N'taking longer than 15 seconds';
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 2, 1, N'taking longer than 15 seconds';
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 3, 1, N'taking longer than 15 seconds';
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 4, 1, N'taking longer than 15 seconds';
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 5, 1, N'taking longer than 15 seconds';

SELECT LogDate, ProcessInfo, LogText
FROM #IOWarningResults
ORDER BY LogDate DESC;

DROP TABLE IF EXISTS #IOWarningResults;

-- Finding 15 second I/O warnings in the SQL Server Error Log is useful evidence of
-- poor I/O performance (which might have many different causes)
-- Look to see if you see any patterns in the results (same files, same drives, same time of day, etc.)


-----------------------------------------------------------------------
-- 5. DRIVE-LEVEL LATENCY (by mount point)
--    Aggregates latency/transfer size by drive and volume mount point.
-----------------------------------------------------------------------
SELECT
    tab.[Drive],
    tab.volume_mount_point AS [Volume Mount Point],
    CASE
        WHEN num_of_reads = 0 THEN 0
        ELSE (io_stall_read_ms/num_of_reads)
    END AS [Read Latency],
    CASE
        WHEN num_of_writes = 0 THEN 0
        ELSE (io_stall_write_ms/num_of_writes)
    END AS [Write Latency],
    CASE
        WHEN (num_of_reads = 0 AND num_of_writes = 0) THEN 0
        ELSE (io_stall/(num_of_reads + num_of_writes))
    END AS [Overall Latency],
    CASE
        WHEN num_of_reads = 0 THEN 0
        ELSE (num_of_bytes_read/num_of_reads)
    END AS [Avg Bytes/Read],
    CASE
        WHEN num_of_writes = 0 THEN 0
        ELSE (num_of_bytes_written/num_of_writes)
    END AS [Avg Bytes/Write],
    CASE
        WHEN (num_of_reads = 0 AND num_of_writes = 0) THEN 0
        ELSE ((num_of_bytes_read + num_of_bytes_written)/(num_of_reads + num_of_writes))
    END AS [Avg Bytes/Transfer]
FROM (
    SELECT
        LEFT(UPPER(mf.physical_name), 2) AS Drive,
        SUM(num_of_reads) AS num_of_reads,
        SUM(io_stall_read_ms) AS io_stall_read_ms,
        SUM(num_of_writes) AS num_of_writes,
        SUM(io_stall_write_ms) AS io_stall_write_ms,
        SUM(num_of_bytes_read) AS num_of_bytes_read,
        SUM(num_of_bytes_written) AS num_of_bytes_written,
        SUM(io_stall) AS io_stall,
        vs.volume_mount_point
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
    INNER JOIN sys.master_files AS mf WITH (NOLOCK)
        ON vfs.database_id = mf.database_id
        AND vfs.[file_id] = mf.[file_id]
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) AS vs
    GROUP BY LEFT(UPPER(mf.physical_name), 2), vs.volume_mount_point
) AS tab
ORDER BY tab.[Drive] OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 6. FILE I/O PROFILE (CURRENT DATABASE)
--    Workload characterization for current database files.
-----------------------------------------------------------------------
SELECT
    DB_NAME(DB_ID()) AS [Database Name],
    df.name AS [Logical Name],
    vfs.[file_id],
    df.type_desc,
    df.physical_name AS [Physical Name],
    CAST(vfs.size_on_disk_bytes/1048576.0 AS DECIMAL(15, 2)) AS [Size on Disk (MB)],
    vfs.num_of_reads,
    vfs.num_of_writes,
    vfs.io_stall_read_ms,
    vfs.io_stall_write_ms,
    CAST(100. * vfs.io_stall_read_ms/(vfs.io_stall_read_ms + vfs.io_stall_write_ms) AS DECIMAL(10,1)) AS [IO Stall Reads Pct],
    CAST(100. * vfs.io_stall_write_ms/(vfs.io_stall_write_ms + vfs.io_stall_read_ms) AS DECIMAL(10,1)) AS [IO Stall Writes Pct],
    (vfs.num_of_reads + vfs.num_of_writes) AS [Writes + Reads],
    CAST(vfs.num_of_bytes_read/1048576.0 AS DECIMAL(15, 2)) AS [MB Read],
    CAST(vfs.num_of_bytes_written/1048576.0 AS DECIMAL(15, 2)) AS [MB Written],
    CAST(100. * vfs.num_of_reads/(vfs.num_of_reads + vfs.num_of_writes) AS DECIMAL(15,1)) AS [# Reads Pct],
    CAST(100. * vfs.num_of_writes/(vfs.num_of_reads + vfs.num_of_writes) AS DECIMAL(15,1)) AS [# Write Pct],
    CAST(100. * vfs.num_of_bytes_read/(vfs.num_of_bytes_read + vfs.num_of_bytes_written) AS DECIMAL(15,1)) AS [Read Bytes Pct],
    CAST(100. * vfs.num_of_bytes_written/(vfs.num_of_bytes_read + vfs.num_of_bytes_written) AS DECIMAL(15,1)) AS [Written Bytes Pct]
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
INNER JOIN sys.database_files AS df WITH (NOLOCK)
    ON vfs.[file_id]= df.[file_id]
OPTION (RECOMPILE);



-----------------------------------------------------------------------
-- 6.1 DATABASE FILE I/O STATISTICS
--     Shows I/O statistics for all database files
-----------------------------------------------------------------------
SELECT
    DB_NAME(fs.database_id) AS DatabaseName,
    mf.name AS FileName,
    mf.type_desc,
    fs.*
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
INNER JOIN sys.master_files AS mf
    ON fs.database_id = mf.database_id
    AND fs.file_id = mf.file_id
ORDER BY fs.database_id, fs.file_id DESC;
GO



-----------------------------------------------------------------------
-- 7. I/O LATENCY PER DATABASE FILE
--    Shows avg read/write latency in milliseconds for each file.
--
--    What to look for:
--      Read latency  > 20ms   → Storage read bottleneck
--      Write latency > 20ms   → Storage write bottleneck
--      Log write latency > 5ms → Transaction log disk is slow
--      Stall percentages help identify whether reads or writes dominate
-----------------------------------------------------------------------
SELECT
    DB_NAME(fs.database_id)                          AS DatabaseName,
    mf.[name]                                        AS LogicalFileName,
    mf.physical_name                                 AS PhysicalPath,
    mf.type_desc                                     AS FileType,

    -- Total I/O counts
    fs.num_of_reads                                  AS TotalReads,
    fs.num_of_writes                                 AS TotalWrites,

    -- Read latency
    CASE
        WHEN fs.num_of_reads = 0 THEN 0
        ELSE CAST(fs.io_stall_read_ms * 1.0 / fs.num_of_reads AS DECIMAL(16,2))
    END                                              AS AvgReadLatencyMs,

    -- Write latency
    CASE
        WHEN fs.num_of_writes = 0 THEN 0
        ELSE CAST(fs.io_stall_write_ms * 1.0 / fs.num_of_writes AS DECIMAL(16,2))
    END                                              AS AvgWriteLatencyMs,

    -- Overall latency
    CASE
        WHEN (fs.num_of_reads + fs.num_of_writes) = 0 THEN 0
        ELSE CAST(fs.io_stall * 1.0 / (fs.num_of_reads + fs.num_of_writes) AS DECIMAL(16,2))
    END                                              AS AvgOverallLatencyMs,

    -- Throughput
    CAST(fs.num_of_bytes_read / 1048576.0 AS DECIMAL(18,2))  AS TotalReadMB,
    CAST(fs.num_of_bytes_written / 1048576.0 AS DECIMAL(18,2)) AS TotalWriteMB,

    -- Stall breakdown
    fs.io_stall_read_ms                              AS ReadStallMs,
    fs.io_stall_write_ms                             AS WriteStallMs,
    fs.io_stall                                      AS TotalStallMs,

    -- Assessment
    CASE
        WHEN mf.type_desc = 'LOG' AND fs.num_of_writes > 0
            AND (fs.io_stall_write_ms * 1.0 / fs.num_of_writes) > 5
        THEN '*** LOG WRITE LATENCY HIGH (>' + CAST(CAST(fs.io_stall_write_ms * 1.0 / fs.num_of_writes AS DECIMAL(10,1)) AS VARCHAR) + 'ms) — move log to faster disk ***'
        WHEN fs.num_of_reads > 0
            AND (fs.io_stall_read_ms * 1.0 / fs.num_of_reads) > 20
        THEN '*** READ LATENCY HIGH — check storage subsystem ***'
        WHEN fs.num_of_writes > 0
            AND (fs.io_stall_write_ms * 1.0 / fs.num_of_writes) > 20
        THEN '*** WRITE LATENCY HIGH — check storage subsystem ***'
        ELSE 'OK'
    END                                              AS LatencyAssessment

FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
INNER JOIN sys.master_files AS mf
    ON fs.database_id = mf.database_id
    AND fs.[file_id] = mf.[file_id]
ORDER BY
    fs.io_stall DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 8. I/O LATENCY SNAPSHOT — DELTA MEASUREMENT (30 seconds)
--    Measures I/O latency for a specific interval rather than
--    cumulative since service start. More accurate for current load.
-----------------------------------------------------------------------

/*
-- Uncomment this block to run the delta measurement

-- Snapshot 1
IF OBJECT_ID('tempdb..#IOStats1') IS NOT NULL DROP TABLE #IOStats1;
SELECT
    database_id, [file_id],
    num_of_reads, num_of_writes,
    io_stall_read_ms, io_stall_write_ms,
    num_of_bytes_read, num_of_bytes_written
INTO #IOStats1
FROM sys.dm_io_virtual_file_stats(NULL, NULL);

-- Wait interval
WAITFOR DELAY '00:00:30';

-- Snapshot 2 with delta
SELECT
    DB_NAME(s2.database_id)                          AS DatabaseName,
    mf.[name]                                        AS LogicalFileName,
    mf.type_desc                                     AS FileType,

    (s2.num_of_reads - s1.num_of_reads)              AS DeltaReads,
    (s2.num_of_writes - s1.num_of_writes)            AS DeltaWrites,

    CASE
        WHEN (s2.num_of_reads - s1.num_of_reads) = 0 THEN 0
        ELSE CAST((s2.io_stall_read_ms - s1.io_stall_read_ms) * 1.0
             / (s2.num_of_reads - s1.num_of_reads) AS DECIMAL(16,2))
    END                                              AS AvgReadLatencyMs,

    CASE
        WHEN (s2.num_of_writes - s1.num_of_writes) = 0 THEN 0
        ELSE CAST((s2.io_stall_write_ms - s1.io_stall_write_ms) * 1.0
             / (s2.num_of_writes - s1.num_of_writes) AS DECIMAL(16,2))
    END                                              AS AvgWriteLatencyMs,

    CAST((s2.num_of_bytes_read - s1.num_of_bytes_read) / 1048576.0
         AS DECIMAL(18,2))                           AS ReadMB_InInterval,
    CAST((s2.num_of_bytes_written - s1.num_of_bytes_written) / 1048576.0
         AS DECIMAL(18,2))                           AS WriteMB_InInterval

FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS s2
INNER JOIN #IOStats1 AS s1
    ON s2.database_id = s1.database_id
    AND s2.[file_id] = s1.[file_id]
INNER JOIN sys.master_files AS mf
    ON s2.database_id = mf.database_id
    AND s2.[file_id] = mf.[file_id]
WHERE (s2.num_of_reads - s1.num_of_reads) + (s2.num_of_writes - s1.num_of_writes) > 0
ORDER BY
    (s2.io_stall_read_ms - s1.io_stall_read_ms)
    + (s2.io_stall_write_ms - s1.io_stall_write_ms) DESC;

-- Cleanup
DROP TABLE #IOStats1;
*/


-----------------------------------------------------------------------
-- 9. AZURE SQL MI IOPS & THROUGHPUT SAMPLER
--    Measures interval IOPS/throughput per file and compares to
--    Azure Premium Storage blob limits.
--
--    Applies to:
--      Azure SQL Managed Instance (General Purpose)
--
--    Notes:
--      - This is a short sampling loop (default 30 seconds)
--      - Excludes local-storage system databases
-----------------------------------------------------------------------
BEGIN TRY

DECLARE @LoopDurationSeconds int = 30;
DECLARE @IntervalLengthMilliseconds int = 1000;

IF @IntervalLengthMilliseconds < 100
    THROW 50001, 'The minimum supported sampling interval duration is 100 ms.', 1;

DECLARE @StartDateTime datetime2(2) = SYSDATETIME();
DECLARE @DelayInterval varchar(12) = DATEADD(millisecond, @IntervalLengthMilliseconds, CAST('00:00:00' AS time(3)));
DECLARE @VFSSample TABLE (
                         SampleMs bigint NOT NULL,
                         DatabaseID smallint NOT NULL,
                         FileID smallint NOT NULL,
                         TransferCount bigint NOT NULL,
                         ByteCount bigint NOT NULL,
                         PRIMARY KEY (SampleMs, DatabaseID, FileID)
                         );

WHILE SYSDATETIME() < DATEADD(second, @LoopDurationSeconds, @StartDateTime)
BEGIN
    INSERT INTO @VFSSample
    (
    SampleMs,
    DatabaseID,
    FileID,
    TransferCount,
    ByteCount
    )
    SELECT vfs.sample_ms AS SampleMs,
           vfs.database_id AS DatabaseID,
           vfs.file_id AS FileID,
           vfs.num_of_reads + vfs.num_of_writes AS TransferCount,
           vfs.num_of_bytes_read + vfs.num_of_bytes_written AS ByteCount
    FROM sys.dm_io_virtual_file_stats(default, default) AS vfs
    WHERE vfs.database_id NOT IN (2,32760,32761,32762,32763)
    ;

    WAITFOR DELAY @DelayInterval;
END;

WITH
BlobLimit AS
(
SELECT 129 AS BlobSizeGB, 500 AS IOPSLimit, 100 AS ThroughputLimit
UNION
SELECT 513, 2300, 150
UNION
SELECT 1025, 5000, 200
UNION
SELECT 2049, 7500, 250
UNION
SELECT 4097, 7500, 250
UNION
SELECT 8192, 12500, 480
),
IntervalPerfMeasure AS
(
SELECT s.DatabaseID,
       s.FileID,
       s.SampleMs,
       (LEAD(s.TransferCount, 1) OVER (PARTITION BY s.DatabaseID, s.FileID ORDER BY s.SampleMs) - s.TransferCount)
       *
       (1000. / (LEAD(s.SampleMs, 1) OVER (PARTITION BY s.DatabaseID, s.FileID ORDER BY s.SampleMs) - s.SampleMs))
       AS IntervalIOPS,
       (
       (LEAD(s.ByteCount, 1) OVER (PARTITION BY s.DatabaseID, s.FileID ORDER BY s.SampleMs) - s.ByteCount)
       /
       ((LEAD(s.SampleMs, 1) OVER (PARTITION BY s.DatabaseID, s.FileID ORDER BY s.SampleMs) - s.SampleMs) * 0.001)
       )
       / 1024 / 1024
       AS IntervalThroughput
FROM @VFSSample AS s
),
FilePerfMeasure AS
(
SELECT DB_NAME(mf.database_id) AS DatabaseName,
       mf.name AS FileLogicalName,
       mf.physical_name AS FilePhysicalName,
       CAST(mf.size * 8. / 1024 / 1024 AS decimal(12,4)) AS FileSizeGB,
       ipm.SampleMs,
       CAST(ipm.IntervalIOPS AS decimal(12,2)) AS IntervalIOPS,
       CAST(ipm.IntervalThroughput AS decimal(12,2)) AS IntervalThroughput
FROM IntervalPerfMeasure AS ipm
INNER JOIN sys.master_files AS mf
ON ipm.DatabaseID = mf.database_id
   AND
   ipm.FileID = mf.file_id
WHERE ipm.IntervalIOPS IS NOT NULL
      AND
      ipm.IntervalThroughput IS NOT NULL
)
SELECT fpm.DatabaseName,
       fpm.FileLogicalName,
       fpm.FilePhysicalName,
       fpm.FileSizeGB,
       bl.BlobSizeGB,
       bl.IOPSLimit,
       MAX(fpm.IntervalIOPS) AS MaxIOPS,
       SUM(IIF(fpm.IntervalIOPS >= bl.IOPSLimit * 0.9, 1, 0)) AS IOPSNearLimitCount,
       bl.ThroughputLimit AS ThroughputLimitMBPS,
       MAX(fpm.IntervalThroughput) AS MaxThroughputMBPS,
       SUM(IIF(fpm.IntervalThroughput >= bl.ThroughputLimit * 0.9, 1, 0)) AS ThroughputNearLimitCount
FROM FilePerfMeasure AS fpm
CROSS APPLY (
            SELECT TOP (1) bl.BlobSizeGB,
                           bl.IOPSLimit,
                           bl.ThroughputLimit
            FROM BlobLimit AS bl
            WHERE bl.BlobSizeGB >= fpm.FileSizeGB
            ORDER BY bl.BlobSizeGB
            ) AS bl
GROUP BY fpm.DatabaseName,
         fpm.FileLogicalName,
         fpm.FilePhysicalName,
         fpm.FileSizeGB,
         bl.BlobSizeGB,
         bl.IOPSLimit,
         bl.ThroughputLimit;

END TRY
BEGIN CATCH
    THROW;
END CATCH;


-----------------------------------------------------------------------
-- 10. PAGEIOLATCH WAITS BY TABLE/INDEX (object-level drill-down)
--    Drills the file-level latency numbers above down to the specific
--    table/index driving the I/O, using per-object page I/O latch
--    stats. Run in the context of the database you want to inspect.
--
--    What to look for:
--      High PageIOLatchWaitMs on a single index = that object is the
--      hot spot behind the PAGEIOLATCH waits seen instance-wide.
--      Compare RangeScanCount vs. SingletonLookupCount — a high scan
--      count relative to seeks often means a missing/unused index.
-----------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA_NAME(ios.object_id)                AS SchemaName,
    OBJECT_NAME(ios.object_id)                        AS TableName,
    ISNULL(i.name, '(heap)')                          AS IndexName,
    i.type_desc                                       AS IndexType,
    ios.page_io_latch_wait_count                      AS PageIOLatchWaitCount,
    ios.page_io_latch_wait_in_ms                       AS PageIOLatchWaitMs,
    CASE
        WHEN ios.page_io_latch_wait_count = 0 THEN 0
        ELSE CAST(ios.page_io_latch_wait_in_ms * 1.0 / ios.page_io_latch_wait_count AS DECIMAL(16,2))
    END                                               AS AvgPageIOLatchWaitMs,
    ios.range_scan_count                              AS RangeScanCount,
    ios.singleton_lookup_count                        AS SingletonLookupCount,
    ios.leaf_insert_count + ios.leaf_update_count
        + ios.leaf_delete_count                       AS LeafModificationCount
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS ios
INNER JOIN sys.objects AS o
    ON ios.object_id = o.object_id
LEFT OUTER JOIN sys.indexes AS i
    ON ios.object_id = i.object_id
    AND ios.index_id = i.index_id
WHERE o.is_ms_shipped = 0
  AND ios.page_io_latch_wait_count > 0
ORDER BY ios.page_io_latch_wait_in_ms DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 11. TOP QUERIES BY PHYSICAL READS (queries driving buffer I/O waits)
--    Identifies the specific cached query plans responsible for the
--    most physical I/O since they were compiled. Directly answers
--    "which queries are mostly bound by buffer I/O?"
--
--    What to look for:
--      High TotalPhysicalReads + high AvgPhysicalReadsPerExec = a
--      query repeatedly forcing disk reads — check its plan for
--      scans, missing indexes, or key/RID lookups (Sections 10/12).
--      Note: resets on plan eviction/recompile — pair with Query
--      Store for a longer history if available.
-----------------------------------------------------------------------
SELECT TOP (50)
    DB_NAME(st.dbid)                                  AS DatabaseName,
    qs.execution_count                                AS ExecutionCount,
    qs.total_physical_reads                           AS TotalPhysicalReads,
    CAST(qs.total_physical_reads * 1.0 / qs.execution_count AS DECIMAL(18,2))
                                                       AS AvgPhysicalReadsPerExec,
    qs.total_logical_reads                            AS TotalLogicalReads,
    qs.total_worker_time / 1000                       AS TotalCpuMs,
    qs.total_elapsed_time / 1000                      AS TotalElapsedMs,
    qs.last_execution_time                            AS LastExecutionTime,
    SUBSTRING(
        st.text,
        (qs.statement_start_offset / 2) + 1,
        (
            (CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)
                ELSE qs.statement_end_offset
             END - qs.statement_start_offset) / 2
        ) + 1
    )                                                  AS QueryText
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE qs.total_physical_reads > 0
ORDER BY qs.total_physical_reads DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 12. MISSING INDEXES CONTRIBUTING TO PHYSICAL I/O
--    Scans/lookups from missing indexes are one of the most common
--    root causes of buffer-I/O-bound queries. Ranks missing index
--    suggestions by estimated overall impact so the highest-value
--    fixes (fewer pages touched -> less physical I/O) surface first.
--
--    What to look for:
--      High ImprovementMeasure with high UserSeeks/UserScans = an
--      index likely to meaningfully cut physical reads if created.
--      Always validate with actual workload testing before deploying.
-----------------------------------------------------------------------
SELECT
    DB_NAME(mid.database_id)                          AS DatabaseName,
    OBJECT_NAME(mid.object_id, mid.database_id)       AS TableName,
    migs.avg_total_user_cost * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans)         AS ImprovementMeasure,
    migs.user_seeks                                   AS UserSeeks,
    migs.user_scans                                   AS UserScans,
    migs.avg_user_impact                              AS AvgPctBenefit,
    mid.equality_columns                              AS EqualityColumns,
    mid.inequality_columns                            AS InequalityColumns,
    mid.included_columns                              AS IncludedColumns,
    'CREATE INDEX IX_' + OBJECT_NAME(mid.object_id, mid.database_id)
        + '_Missing_' + CAST(mig.index_handle AS VARCHAR(10))
        + ' ON ' + mid.statement
        + ' (' + ISNULL(mid.equality_columns, '')
        + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ',' ELSE '' END
        + ISNULL(mid.inequality_columns, '') + ')'
        + ISNULL(' INCLUDE (' + mid.included_columns + ')', '') AS SuggestedCreateIndexStatement
FROM sys.dm_db_missing_index_groups AS mig
INNER JOIN sys.dm_db_missing_index_group_stats AS migs
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY ImprovementMeasure DESC
OPTION (RECOMPILE);


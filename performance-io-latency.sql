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
-- 1. I/O LATENCY PER DATABASE FILE
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
-- 4. PENDING I/O REQUESTS (live snapshot)
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
-- 5. I/O LATENCY SNAPSHOT — DELTA MEASUREMENT (30 seconds)
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

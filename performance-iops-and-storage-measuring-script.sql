-----------------------------------------------------------------------
-- IOPS & STORAGE THROUGHPUT MEASURING (AZURE SQL MI)
-- Purpose : Measure IOPS/throughput per database file and compare
--           against Azure Premium Storage blob limits.
-- Safety  : Read-only measurement loop. Does not modify data.
-- Applies to : Azure SQL Managed Instance (General Purpose)
-----------------------------------------------------------------------
/*
This script is intended to be executed on Azure SQL Database Managed Instance (General Purpose)
to determine if the IOPS/throughput seen against each database file in remote storage during script 
execution are near Azure Premium Storage limits for the blob corresponding to the file.

The script helps in determining if using larger files/blobs with higher limits
would be beneficial for improving workload performance.

NOTE: This script reports IOPS as they are measured by SQL Server. Azure Premium Storage measures 
them differently. For IOs up to 256 KB, both measurements match. For larger IOs, Azure Premium Storage 
breaks each IO into 256 KB chunks, and counts each chunk as an IO. Therefore, if SQL Server issues 
IOs larger than 256 KB, e.g. during backup/restore, then IOPS reported by this script will be lower 
than the IOPS measured by Azure Premium Storage. In this case, IOPS-based throttling could be 
occurring even if not reported in the script output.
*/

SET NOCOUNT ON;

BEGIN TRY

-- Begin parameters section

-- Change sampling loop duration to collect data over a representative time interval
DECLARE @LoopDurationSeconds int = 30;

-- Change the length of the interval between samplings of sys.dm_io_virtual_file_stats() for more or less granular sampling
DECLARE @IntervalLengthMilliseconds int = 1000;

-- End parameters section

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

-- Collect samples of virtual file stats for the specified duration
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
    WHERE vfs.database_id NOT IN (2,32760,32761,32762,32763) -- Exclude databases on local storage
    ;

    WAITFOR DELAY @DelayInterval;
END;

-- Return result set. 
-- Each row represents a database file, and includes max IOPS/throughput seen against the file, 
-- as well as counters showing how many times file IOPS/throughput were near Premium Storage limits during sampling loop execution.
WITH 
-- Define Azure Premium Storage limits (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/premium-storage#premium-storage-disk-limits)
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
-- Calculate IOPS/throughput per file for each sampling interval,
-- by subtracting the cumulative stats of the previous sample 
-- from the cumulative stats of the next sample.
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
       AS IntervalThroughput -- In MB/s
FROM @VFSSample AS s
),
-- Add columns for database name, file names, and file size
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
WHERE -- Remove rows without corresponding next sample
      ipm.IntervalIOPS IS NOT NULL
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
         bl.ThroughputLimit
;

END TRY
BEGIN CATCH
    THROW;
END CATCH;


-- This shows all of your drives, not just LUNs with SQL Server database files

-- New in SQL Server 2017





-- sys.dm_os_enumerate_fixed_drives (Transact-SQL)

-- https://bit.ly/2EZoHLj













-- Volume info for all LUNS that have database files on the current instance (Query 30) (Volume Info)

SELECT DISTINCT vs.volume_mount_point, vs.file_system_type, vs.logical_volume_name, 

CONVERT(DECIMAL(18,2), vs.total_bytes/1073741824.0) AS [Total Size (GB)],

CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [Available Size (GB)],  

CONVERT(DECIMAL(18,2), vs.available_bytes * 1. / vs.total_bytes * 100.) AS [Space Free %],

vs.supports_compression, vs.is_compressed, 

vs.supports_sparse_files, vs.supports_alternate_streams

FROM sys.master_files AS f WITH (NOLOCK)

CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs 

ORDER BY vs.volume_mount_point OPTION (RECOMPILE);

------





-- Shows you the total and free space on the LUNs where you have database files

-- Being low on free space can negatively affect performance





-- sys.dm_os_volume_stats (Transact-SQL)

-- https://bit.ly/2oBPNNr













-- Drive level latency information (Query 31) (Drive Level Latency)

SELECT tab.[Drive], tab.volume_mount_point AS [Volume Mount Point], 



-- Drive level latency information (Query 31) (Drive Level Latency)

SELECT tab.[Drive], tab.volume_mount_point AS [Volume Mount Point], 

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

FROM (SELECT LEFT(UPPER(mf.physical_name), 2) AS Drive, SUM(num_of_reads) AS num_of_reads,

	         SUM(io_stall_read_ms) AS io_stall_read_ms, SUM(num_of_writes) AS num_of_writes,

	         SUM(io_stall_write_ms) AS io_stall_write_ms, SUM(num_of_bytes_read) AS num_of_bytes_read,

	         SUM(num_of_bytes_written) AS num_of_bytes_written, SUM(io_stall) AS io_stall, vs.volume_mount_point 



-- Shows you the drive-level latency for reads and writes, in milliseconds

-- Latency above 30-40ms is usually a problem

-- These latency numbers include all file activity against all SQL Server 

-- database files on each drive since SQL Server was last started





-- sys.dm_io_virtual_file_stats (Transact-SQL)

-- https://bit.ly/3bRWUc0





-- sys.dm_os_volume_stats (Transact-SQL)

-- https://bit.ly/33thz2j









-- Calculates average latency per read, per write, and per total input/output for each database file  (Query 32) (IO Latency by File)

SELECT DB_NAME(fs.database_id) AS [Database Name], CAST(fs.io_stall_read_ms/(1.0 + fs.num_of_reads) AS NUMERIC(10,1)) AS [avg_read_latency_ms],

CAST(fs.io_stall_write_ms/(1.0 + fs.num_of_writes) AS NUMERIC(10,1)) AS [avg_write_latency_ms],

CAST((fs.io_stall_read_ms + fs.io_stall_write_ms)/(1.0 + fs.num_of_reads + fs.num_of_writes) AS NUMERIC(10,1)) AS [avg_io_latency_ms],

CONVERT(DECIMAL(18,2), mf.size/128.0) AS [File Size (MB)], mf.physical_name, mf.type_desc, fs.io_stall_read_ms, fs.num_of_reads, 

fs.io_stall_write_ms, fs.num_of_writes, fs.io_stall_read_ms + fs.io_stall_write_ms AS [io_stalls], fs.num_of_reads + fs.num_of_writes AS [total_io],

io_stall_queued_read_ms AS [Resource Governor Total Read IO Latency (ms)], io_stall_queued_write_ms AS [Resource Governor Total Write IO Latency (ms)] 

FROM sys.dm_io_virtual_file_stats(null,null) AS fs

INNER JOIN sys.master_files AS mf WITH (NOLOCK)

ON fs.database_id = mf.database_id

AND fs.[file_id] = mf.[file_id]

ORDER BY avg_io_latency_ms DESC OPTION (RECOMPILE);

------





-- Getting missing index information for all of the databases on the instance is very useful

-- Look at last user seek time, number of user seeks to help determine source and importance

-- Also look at avg_user_impact and avg_total_user_cost to help determine importance

-- SQL Server is overly eager to add included columns, so beware

-- Do not just blindly add indexes that show up from this query!!!

-- H�kan Winther has given me some great suggestions for this query





-- SQL Server Index Design Guide

-- https://bit.ly/2qtZr4N













-- Get VLF Counts for all databases on the instance (Query 37) (VLF Counts)

SELECT [name] AS [Database Name], [VLF Count]

FROM sys.databases AS db WITH (NOLOCK)

CROSS APPLY (SELECT file_id, COUNT(*) AS [VLF Count]

		     FROM sys.dm_db_log_info(db.database_id)

			 GROUP BY file_id) AS li

ORDER BY [VLF Count] DESC OPTION (RECOMPILE);

------







-- sys.dm_exec_function_stats (Transact-SQL)

-- https://bit.ly/2q1Q6BM





-- Showplan Enhancements for UDFs

-- https://bit.ly/2LVqiQ1













-- Look for long duration buffer pool scans (Query 56) (Long Buffer Pool Scans)

EXEC sys.xp_readerrorlog 0, 1, N'Buffer pool scan took';

------





-- Finds buffer pool scans that took more than 10 seconds in the current SQL Server Error log

-- This should happen much less often in SQL Server 2022



-- I/O Statistics by file for the current database  (Query 61) (IO Stats By File)

SELECT DB_NAME(DB_ID()) AS [Database Name], df.name AS [Logical Name], vfs.[file_id], df.type_desc,

df.physical_name AS [Physical Name], CAST(vfs.size_on_disk_bytes/1048576.0 AS DECIMAL(15, 2)) AS [Size on Disk (MB)],

vfs.num_of_reads, vfs.num_of_writes, vfs.io_stall_read_ms, vfs.io_stall_write_ms,

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

ON vfs.[file_id]= df.[file_id] OPTION (RECOMPILE);

------





-- This helps you characterize your workload better from an I/O perspective for this database

-- It helps you determine whether you have an OLTP or DW/DSS type of workload











-- Get most frequently executed queries for this database (Query 62) (Query Execution Counts)

SELECT TOP(50) LEFT(t.[text], 50) AS [Short Query Text], qs.execution_count AS [Execution Count],

ISNULL(qs.execution_count/DATEDIFF(Minute, qs.creation_time, GETDATE()), 0) AS [Calls/Minute],

qs.total_logical_reads AS [Total Logical Reads],

qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],

qs.total_worker_time AS [Total Worker Time],

qs.total_worker_time/qs.execution_count AS [Avg Worker Time], 

qs.total_elapsed_time AS [Total Elapsed Time],

qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],

CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index], 

qs.last_execution_time AS [Last Execution Time], qs.creation_time AS [Creation Time]

--,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel

FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)

CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 

CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 

WHERE t.dbid = DB_ID()

AND DATEDIFF(Minute, qs.creation_time, GETDATE()) > 0

ORDER BY qs.execution_count DESC OPTION (RECOMPILE);

------





-- Tells you which cached queries are called the most often

-- This helps you characterize and baseline your workload

-- It also helps you find possible caching opportunities





-- Tells you which cached stored procedures are called the most often

-- This helps you characterize and baseline your workload

-- It also helps you find possible caching opportunities









-- Top Cached SPs By Avg Elapsed Time (Query 64) (SP Avg Elapsed Time)

SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.min_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time], 

qs.max_elapsed_time, qs.last_elapsed_time, qs.total_elapsed_time, qs.execution_count, 

ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute], 

qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], 

qs.total_worker_time AS [TotalWorkerTime],

CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],

CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
-----------------------------------------------------------------------
-- BACKUP VERIFICATION & CHAIN INTEGRITY
-- Purpose : Verify backup files, check backup chain completeness,
--           identify databases with missing or outdated backups,
--           and monitor backup performance.
-- Safety  : RESTORE VERIFYONLY is read-only — it does NOT restore.
--           All other queries are pure SELECTs.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. RESTORE VERIFYONLY — validate a backup file is readable
--    Does NOT restore — just validates header, checksums, and structure.
-----------------------------------------------------------------------
-- Single backup file:
-- RESTORE VERIFYONLY FROM DISK = N'C:\Backups\YourDB_Full.bak' WITH CHECKSUM;

-- With multiple stripe files:
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\Backups\YourDB_Stripe1.bak',
--          DISK = N'C:\Backups\YourDB_Stripe2.bak'
--     WITH CHECKSUM;

-----------------------------------------------------------------------
-- 2. GENERATE VERIFYONLY FOR ALL RECENT FULL BACKUPS
-----------------------------------------------------------------------
SELECT
    bs.database_name,
    bs.backup_finish_date,
    bmf.physical_device_name,
    'RESTORE VERIFYONLY FROM DISK = N'''
        + bmf.physical_device_name
        + ''' WITH CHECKSUM;'                    AS VerifyCommand
FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily bmf
        ON bs.media_set_id = bmf.media_set_id
WHERE bs.[type] = 'D'                            -- Full backups only
  AND bs.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY bs.backup_finish_date DESC;

-----------------------------------------------------------------------
-- 3. LAST BACKUP OF EACH TYPE PER DATABASE
--    Quickly spot databases missing recent backups.
-----------------------------------------------------------------------
SELECT
    d.[name]                                      AS DatabaseName,
    d.recovery_model_desc                         AS RecoveryModel,
    d.state_desc                                  AS DatabaseState,

    -- Last Full
    MAX(CASE WHEN bs.[type] = 'D'
             THEN bs.backup_finish_date END)      AS LastFullBackup,
    DATEDIFF(HOUR,
        MAX(CASE WHEN bs.[type] = 'D'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS HoursSinceFullBackup,

    -- Last Differential
    MAX(CASE WHEN bs.[type] = 'I'
             THEN bs.backup_finish_date END)      AS LastDiffBackup,

    -- Last Log
    MAX(CASE WHEN bs.[type] = 'L'
             THEN bs.backup_finish_date END)      AS LastLogBackup,
    DATEDIFF(MINUTE,
        MAX(CASE WHEN bs.[type] = 'L'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS MinSinceLogBackup,

    -- Alerts
    CASE
        WHEN MAX(CASE WHEN bs.[type] = 'D'
                      THEN bs.backup_finish_date END) IS NULL
            THEN '*** NO FULL BACKUP ***'
        WHEN DATEDIFF(HOUR,
                MAX(CASE WHEN bs.[type] = 'D'
                         THEN bs.backup_finish_date END),
                GETDATE()) > 168                  -- > 7 days
            THEN '*** FULL BACKUP OVERDUE ***'
        ELSE 'OK'
    END                                           AS FullBackupStatus,

    CASE
        WHEN d.recovery_model_desc = 'FULL'
         AND MAX(CASE WHEN bs.[type] = 'L'
                      THEN bs.backup_finish_date END) IS NULL
            THEN '*** NO LOG BACKUP (FULL recovery!) ***'
        WHEN d.recovery_model_desc = 'FULL'
         AND DATEDIFF(MINUTE,
                MAX(CASE WHEN bs.[type] = 'L'
                         THEN bs.backup_finish_date END),
                GETDATE()) > 60
            THEN '*** LOG BACKUP OVERDUE ***'
        ELSE 'OK'
    END                                           AS LogBackupStatus

FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON d.[name] = bs.database_name
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
  AND d.source_database_id IS NULL                -- exclude snapshots
GROUP BY d.[name], d.recovery_model_desc, d.state_desc
ORDER BY HoursSinceFullBackup DESC;

-----------------------------------------------------------------------
-- 4. BACKUP CHAIN INTEGRITY
--    For FULL-recovery databases, check that the log backup chain
--    has no gaps (each log backup's first_lsn = prior's last_lsn).
-----------------------------------------------------------------------
;WITH LogChain AS (
    SELECT
        database_name,
        backup_finish_date,
        first_lsn,
        last_lsn,
        LAG(last_lsn) OVER (
            PARTITION BY database_name
            ORDER BY backup_finish_date) AS prev_last_lsn
    FROM msdb.dbo.backupset
    WHERE [type] = 'L'
      AND backup_finish_date >= DATEADD(DAY, -7, GETDATE())
)
SELECT
    database_name,
    backup_finish_date,
    first_lsn,
    prev_last_lsn,
    CASE
        WHEN prev_last_lsn IS NULL THEN 'First in window'
        WHEN first_lsn = prev_last_lsn THEN 'Chain OK'
        ELSE '*** CHAIN BREAK ***'
    END AS ChainStatus
FROM LogChain
WHERE prev_last_lsn IS NOT NULL
  AND first_lsn <> prev_last_lsn
ORDER BY database_name, backup_finish_date;

-----------------------------------------------------------------------
-- 5. BACKUP PERFORMANCE — size, duration, throughput
-----------------------------------------------------------------------
SELECT TOP 50
    bs.database_name,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                                           AS BackupType,
    bs.backup_start_date,
    bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_start_date,
                     bs.backup_finish_date)       AS DurationSec,
    CAST(bs.backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS BackupSizeMB,
    CAST(bs.compressed_backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS CompressedMB,
    CAST(100.0 - (bs.compressed_backup_size * 100.0
         / NULLIF(bs.backup_size, 0))
         AS DECIMAL(5,2))                         AS CompressionPct,
    CAST(bs.backup_size / 1048576.0
         / NULLIF(DATEDIFF(SECOND,
             bs.backup_start_date,
             bs.backup_finish_date), 0)
         AS DECIMAL(18,2))                        AS ThroughputMBps,
    bs.is_encrypted,
    bs.has_backup_checksums
FROM msdb.dbo.backupset bs
ORDER BY bs.backup_finish_date DESC;

-----------------------------------------------------------------------
-- 6. BACKUP FILES WITH CHECKSUM STATUS
--    Backups taken without CHECKSUM can't catch silent corruption.
-----------------------------------------------------------------------
SELECT
    bs.database_name,
    bs.backup_finish_date,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                              AS BackupType,
    bs.has_backup_checksums,
    CASE
        WHEN bs.has_backup_checksums = 0
            THEN '*** NO CHECKSUM ***'
        ELSE 'OK'
    END                              AS ChecksumStatus,
    bmf.physical_device_name
FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily bmf
        ON bs.media_set_id = bmf.media_set_id
WHERE bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
  AND bs.has_backup_checksums = 0
ORDER BY bs.backup_finish_date DESC;

-----------------------------------------------------------------------
-- 7. RESTORE HEADER — inspect backup file contents
-----------------------------------------------------------------------
-- RESTORE HEADERONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';
-- RESTORE FILELISTONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';

-----------------------------------------------------------------------
-- 8. DATABASES IN FULL RECOVERY WITHOUT RECENT LOG BACKUPS
--    These databases will have growing transaction logs!
-----------------------------------------------------------------------
SELECT
    d.[name]                  AS DatabaseName,
    d.recovery_model_desc     AS RecoveryModel,
    d.log_reuse_wait_desc     AS LogReuseWait,
    MAX(bs.backup_finish_date) AS LastLogBackup,
    DATEDIFF(MINUTE,
        MAX(bs.backup_finish_date),
        GETDATE())            AS MinutesSinceLastLog
FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs
        ON d.[name] = bs.database_name AND bs.[type] = 'L'
WHERE d.recovery_model_desc = 'FULL'
  AND d.database_id > 4
  AND d.state_desc = 'ONLINE'
GROUP BY d.[name], d.recovery_model_desc, d.log_reuse_wait_desc
HAVING MAX(bs.backup_finish_date) IS NULL
    OR DATEDIFF(MINUTE, MAX(bs.backup_finish_date), GETDATE()) > 60
ORDER BY MinutesSinceLastLog DESC;

-----------------------------------------------------------------------
-- 9. DETAILED BACKUP HISTORY (all backup types, all metadata)
--    Shows device type, LSNs, encryption, compression for forensics.
-----------------------------------------------------------------------
SELECT TOP 5000
    bcks.database_name,
    bckMF.device_type,
    BackD.type_desc                           AS DeviceTypeDesc,
    BackD.physical_name                       AS BackupDeviceName,
    bckS.[type]                               AS BackupTypeCode,
    CASE bckS.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Transaction Log'
    END                                       AS BackupType,
    bckS.backup_start_date,
    bckS.backup_finish_date,
    CONVERT(CHAR(8),
        DATEADD(s,
            DATEDIFF(s, bckS.backup_start_date, bckS.backup_finish_date),
            '1900-1-1'),
        8)                                    AS BackupDuration_hms,
    CONVERT(DECIMAL(19,2),
        (bckS.backup_size * 1.0) / POWER(2,20)) AS BackupSizeMB,
    CAST(bcks.backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS BackupSizeGB,
    CONVERT(DECIMAL(19,2),
        (bckS.compressed_backup_size * 1.0) / POWER(2,20))
                                              AS CompressedBackupSizeMB,
    CAST(bcks.compressed_backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS CompressedBackupSizeGB,
    software_name,
    is_compressed,
    is_copy_only,
    is_encrypted,
    physical_device_name,
    first_lsn,
    last_lsn,
    checkpoint_lsn,
    database_backup_lsn,
    user_name,
    @@SERVERNAME                              AS ServerName
FROM msdb.dbo.backupset bckS
    INNER JOIN msdb.dbo.backupmediaset bckMS
        ON bckS.media_set_id = bckMS.media_set_id
    INNER JOIN msdb.dbo.backupmediafamily bckMF
        ON bckMS.media_set_id = bckMF.media_set_id
    LEFT JOIN sys.backup_devices BackD
        ON bckMF.device_type = BackD.[type]
-- WHERE database_name = 'YourDBName'
ORDER BY bckS.backup_start_date DESC;

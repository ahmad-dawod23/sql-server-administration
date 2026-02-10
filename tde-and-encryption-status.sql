-----------------------------------------------------------------------
-- TDE, ENCRYPTION & CERTIFICATE MANAGEMENT
-- Purpose : Audit Transparent Data Encryption status, certificate
--           expiry, Always Encrypted column master keys, and
--           backup encryption settings.
-- Safety  : All queries are read-only.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. TDE STATUS — ALL DATABASES (detailed with progress)
-----------------------------------------------------------------------
SELECT
    DB_NAME(dek.database_id)        AS DatabaseName,
    d.is_encrypted                  AS IsEncryptedFlag,
    dek.encryption_state,
    CASE dek.encryption_state
        WHEN 0 THEN 'No encryption key'
        WHEN 1 THEN 'Unencrypted'
        WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'Encrypted'
        WHEN 4 THEN 'Key change in progress'
        WHEN 5 THEN 'Decryption in progress'
        WHEN 6 THEN 'Protection change in progress'
    END                             AS EncryptionStateDesc,
    dek.percent_complete            AS PercentComplete,
    dek.key_algorithm,
    dek.key_length,
    c.[name]                        AS CertificateName,
    c.expiry_date                   AS CertExpiryDate,
    DATEDIFF(DAY, GETDATE(), c.expiry_date) AS DaysUntilExpiry,
    CASE
        WHEN c.expiry_date < GETDATE()
            THEN '*** EXPIRED ***'
        WHEN DATEDIFF(DAY, GETDATE(), c.expiry_date) < 30
            THEN '*** EXPIRING SOON ***'
        ELSE 'OK'
    END                             AS CertStatus,
    dek.encryptor_type
FROM sys.dm_database_encryption_keys dek
    LEFT JOIN sys.databases d
        ON dek.database_id = d.database_id
    LEFT JOIN master.sys.certificates c
        ON dek.encryptor_thumbprint = c.thumbprint
ORDER BY dek.encryption_state DESC;

-----------------------------------------------------------------------
-- 2. DATABASES WITHOUT TDE
-----------------------------------------------------------------------
SELECT
    d.[name]                AS DatabaseName,
    d.state_desc            AS [State],
    'NOT ENCRYPTED'         AS TDEStatus
FROM sys.databases d
    LEFT JOIN sys.dm_database_encryption_keys dek
        ON d.database_id = dek.database_id
WHERE dek.database_id IS NULL
  AND d.database_id > 4    -- exclude system databases
  AND d.state_desc = 'ONLINE'
ORDER BY d.[name];

-----------------------------------------------------------------------
-- 3. ALL CERTIFICATES IN master DATABASE
--    Check for expiring certificates that protect TDE keys or backups.
-----------------------------------------------------------------------
SELECT
    [name]                           AS CertificateName,
    [subject],
    start_date,
    expiry_date,
    DATEDIFF(DAY, GETDATE(), expiry_date) AS DaysUntilExpiry,
    CASE
        WHEN expiry_date < GETDATE()
            THEN '*** EXPIRED ***'
        WHEN DATEDIFF(DAY, GETDATE(), expiry_date) < 30
            THEN '*** EXPIRING SOON ***'
        WHEN DATEDIFF(DAY, GETDATE(), expiry_date) < 90
            THEN '* Warning *'
        ELSE 'OK'
    END                              AS [Status],
    pvt_key_encryption_type_desc     AS PrivateKeyEncryption,
    thumbprint
FROM master.sys.certificates
ORDER BY expiry_date;

-----------------------------------------------------------------------
-- 4. SERVICE MASTER KEY AND DATABASE MASTER KEY STATUS
-----------------------------------------------------------------------
-- Service Master Key (instance-level):
SELECT
    'Service Master Key'          AS KeyType,
    key_length,
    algorithm_desc
FROM master.sys.symmetric_keys
WHERE [name] = '##MS_ServiceMasterKey##';

-- Database Master Keys (per database):
SELECT
    DB_NAME()                     AS DatabaseName,
    [name],
    key_length,
    algorithm_desc,
    create_date,
    modify_date,
    pvt_key_encryption_type_desc  AS EncryptionType
FROM sys.symmetric_keys
WHERE [name] = '##MS_DatabaseMasterKey##';

-----------------------------------------------------------------------
-- 5. ALWAYS ENCRYPTED — COLUMN MASTER KEYS (current database)
-----------------------------------------------------------------------
SELECT
    cmk.[name]                     AS ColumnMasterKeyName,
    cmk.key_store_provider_name    AS KeyStoreProvider,
    cmk.key_path                   AS KeyPath,
    cmk.create_date
FROM sys.column_master_keys cmk
ORDER BY cmk.[name];

-----------------------------------------------------------------------
-- 6. ALWAYS ENCRYPTED — COLUMN ENCRYPTION KEYS (current database)
-----------------------------------------------------------------------
SELECT
    cek.[name]                     AS ColumnEncryptionKeyName,
    cmk.[name]                     AS ColumnMasterKeyName,
    cek.create_date,
    cekv.encryption_algorithm_name AS Algorithm
FROM sys.column_encryption_keys cek
    JOIN sys.column_encryption_key_values cekv
        ON cek.column_encryption_key_id = cekv.column_encryption_key_id
    JOIN sys.column_master_keys cmk
        ON cekv.column_master_key_id = cmk.column_master_key_id
ORDER BY cek.[name];

-----------------------------------------------------------------------
-- 7. ENCRYPTED COLUMNS (current database)
-----------------------------------------------------------------------
SELECT
    SCHEMA_NAME(t.[schema_id])     AS [Schema],
    t.[name]                       AS TableName,
    c.[name]                       AS ColumnName,
    c.encryption_type_desc         AS EncryptionType,
    cek.[name]                     AS ColumnEncryptionKey,
    c.encryption_algorithm_name    AS Algorithm
FROM sys.columns c
    JOIN sys.tables t              ON c.[object_id] = t.[object_id]
    LEFT JOIN sys.column_encryption_keys cek
        ON c.column_encryption_key_id = cek.column_encryption_key_id
WHERE c.encryption_type IS NOT NULL
ORDER BY t.[name], c.[name];

-----------------------------------------------------------------------
-- 8. BACKUP ENCRYPTION STATUS
--    Shows whether recent backups were encrypted.
-----------------------------------------------------------------------
SELECT TOP 50
    bs.database_name,
    bs.backup_finish_date,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                              AS BackupType,
    bs.is_encrypted,
    bs.key_algorithm,
    bs.encryptor_type,
    bs.encryptor_thumbprint,
    c.[name]                         AS CertificateName,
    CAST(bs.backup_size / 1048576.0 AS DECIMAL(18,2)) AS BackupSizeMB,
    CAST(bs.compressed_backup_size / 1048576.0 AS DECIMAL(18,2)) AS CompressedMB
FROM msdb.dbo.backupset bs
    LEFT JOIN master.sys.certificates c
        ON bs.encryptor_thumbprint = c.thumbprint
ORDER BY bs.backup_finish_date DESC;

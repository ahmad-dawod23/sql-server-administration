/*
================================================================================
  BLOCKING, DEADLOCK & INDEX FRAGMENTATION SIMULATIONS
================================================================================
  Purpose:  Demonstrate blocking, deadlocks, and index fragmentation in SQL Server.
  Usage:    Run each numbered section in SEPARATE SSMS query windows as noted.
  Requires: sysadmin or dbcreator to create StoreDB; db_owner within StoreDB.
================================================================================
*/

-- ============================================================================
-- 0. SETUP: Create Database, Table, and Seed Data
-- ============================================================================
IF DB_ID('StoreDB') IS NULL
    CREATE DATABASE StoreDB;
GO

USE StoreDB;
GO

DROP TABLE IF EXISTS dbo.Products;
GO

CREATE TABLE dbo.Products (
    ProductID      INT            PRIMARY KEY IDENTITY(1,1),
    ProductName    VARCHAR(255)   NOT NULL,
    SKU            VARCHAR(50)    UNIQUE NOT NULL,
    UnitPrice      DECIMAL(10,2)  NOT NULL,
    StockQuantity  INT            NOT NULL,
    LastUpdated    DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME()
);
GO

-- NCI on ProductName — will fragment heavily with random inserts (Section 3)
CREATE NONCLUSTERED INDEX IX_Products_ProductName
    ON dbo.Products(ProductName);
GO

INSERT INTO dbo.Products (ProductName, SKU, UnitPrice, StockQuantity)
VALUES
    ('Laptop Pro X',          'LPX-001', 1200.00, 50),
    ('Wireless Mouse G',      'WMG-002',   25.50, 200),
    ('Mechanical Keyboard Z', 'MKZ-003',   75.00, 100),
    ('4K Monitor Ultra',      '4KM-004',  350.00, 30),
    ('Webcam HD Plus',        'WHP-005',   49.99, 150);
GO

SELECT * FROM dbo.Products;
GO


-- ============================================================================
-- 1. BLOCKING SIMULATION  (requires 2 SSMS windows)
-- ============================================================================
/*
  How it works:
    Session 1 takes an X lock on ProductID=1 via UPDATE inside an open transaction.
    Session 2 tries to read the same row and is blocked until Session 1 commits/rolls back.

  Steps:
    1. Run "SESSION 1 — BLOCKER" in Window 1.
    2. Within 30 seconds, run "SESSION 2 — BLOCKED" in Window 2.
    3. Session 2 hangs until Session 1's WAITFOR expires and the ROLLBACK fires.
    4. Optionally run the monitoring query from any third window to observe the block.
*/

-- ---- SESSION 1 — BLOCKER (run in Window 1) ----
USE StoreDB;
GO

SET XACT_ABORT ON;  -- auto-rollback on errors

BEGIN TRANSACTION;

    UPDATE dbo.Products
    SET    StockQuantity = StockQuantity - 1,
           LastUpdated   = SYSDATETIME()
    WHERE  ProductID = 1;

    -- Verify the uncommitted change
    SELECT ProductID, ProductName, StockQuantity, LastUpdated
    FROM   dbo.Products
    WHERE  ProductID = 1;

    -- Hold the lock open for 30 seconds so you can start Session 2
    WAITFOR DELAY '00:00:30';

ROLLBACK TRANSACTION;   -- change to COMMIT if desired

-- Confirm row reverted
SELECT ProductID, ProductName, StockQuantity, LastUpdated
FROM   dbo.Products
WHERE  ProductID = 1;
GO


-- ---- SESSION 2 — BLOCKED (run in Window 2 while Session 1 is waiting) ----
USE StoreDB;
GO

-- This SELECT requests an S lock on ProductID=1, blocked by Session 1's X lock
SELECT ProductID, ProductName, StockQuantity, LastUpdated
FROM   dbo.Products
WHERE  ProductID = 1;
-- Query completes once Session 1 releases its lock

-- Tip: add WITH (NOLOCK) or SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
-- to read without waiting (dirty read), or use READ COMMITTED SNAPSHOT for
-- non-blocking reads without dirty data.
GO


-- ---- MONITORING — view blocked sessions (run from any window) ----
-- Quick blocked process check
SELECT
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time / 1000.0 AS wait_seconds,
    r.status,
    DB_NAME(r.database_id) AS db_name,
    t.text AS sql_text,
    r.command
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;
GO


-- ============================================================================
-- 2. DEADLOCK SIMULATION  (requires 2 SSMS windows)
-- ============================================================================
/*
  How it works:
    Session A locks ProductID=2 then waits, then requests ProductID=3.
    Session B locks ProductID=3 then requests ProductID=2.
    Circular wait → SQL Server kills one session with error 1205.

  Steps:
    1. Run "SESSION A" in Window 1; it locks row 2, then pauses 5 seconds.
    2. Immediately run "SESSION B" in Window 2; it locks row 3, then requests row 2.
    3. After 5s, Session A requests row 3 → deadlock detected within seconds.
    4. One session receives error 1205; the other completes normally.

  Tip: SET DEADLOCK_PRIORITY LOW on the session you'd prefer to be the victim.
*/

-- ---- SESSION A (run in Window 1) ----
USE StoreDB;
GO

SET XACT_ABORT ON;
-- SET DEADLOCK_PRIORITY LOW;  -- uncomment to make this the preferred victim

BEGIN TRY
    BEGIN TRANSACTION;

        -- Step 1: lock row 2
        UPDATE dbo.Products
        SET    UnitPrice = UnitPrice + 0.01
        WHERE  ProductID = 2;

        -- Pause — gives you time to start Session B
        WAITFOR DELAY '00:00:05';

        -- Step 2: request row 3 (held by Session B → deadlock)
        UPDATE dbo.Products
        SET    UnitPrice = UnitPrice + 0.01
        WHERE  ProductID = 3;

    COMMIT TRANSACTION;
    PRINT 'Session A committed successfully.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Session A error: ' + ERROR_MESSAGE();
END CATCH;
GO


-- ---- SESSION B (run in Window 2 right after starting Session A) ----
USE StoreDB;
GO

SET XACT_ABORT ON;
-- SET DEADLOCK_PRIORITY HIGH;  -- uncomment to make this the survivor

BEGIN TRY
    BEGIN TRANSACTION;

        -- Step 1: lock row 3
        UPDATE dbo.Products
        SET    StockQuantity = StockQuantity - 1
        WHERE  ProductID = 3;

        -- Step 2: request row 2 (held by Session A → deadlock)
        UPDATE dbo.Products
        SET    StockQuantity = StockQuantity - 1
        WHERE  ProductID = 2;

    COMMIT TRANSACTION;
    PRINT 'Session B committed successfully.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Session B error: ' + ERROR_MESSAGE();
END CATCH;
GO


-- ---- DEADLOCK MONITORING — capture deadlock graph via Extended Events ----
/*
  The system_health XE session captures deadlock graphs by default on SQL 2012+.
  Query the ring buffer to pull the most recent deadlock XML:
*/
SELECT
    xdr.value('@timestamp', 'DATETIME2')                   AS deadlock_time,
    xdr.query('(data/value/deadlock)[1]')                   AS deadlock_graph
FROM (
    SELECT CAST(target_data AS XML) AS target_xml
    FROM   sys.dm_xe_session_targets AS t
    JOIN   sys.dm_xe_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = 'system_health'
      AND  t.target_name = 'ring_buffer'
) AS x
CROSS APPLY target_xml.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS xevt(xdr)
ORDER BY deadlock_time DESC;
GO


-- ============================================================================
-- 3. MASS INSERT FOR INDEX FRAGMENTATION
-- ============================================================================
/*
  Inserts 50K rows with random ProductName and SKU values.
  The clustered index (IDENTITY) stays mostly ordered.
  The NCI on ProductName fragments heavily due to random key values causing page splits.
*/
USE StoreDB;
GO

SET NOCOUNT ON;

DECLARE @MaxRecords INT = 50000;
DECLARE @BatchSize  INT = 1000;
DECLARE @Inserted   INT = 0;

WHILE @Inserted < @MaxRecords
BEGIN
    -- Insert in 1000-row batches using a numbers CTE (much faster than row-by-row)
    ;WITH Numbers AS (
        SELECT TOP (@BatchSize)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    )
    INSERT INTO dbo.Products (ProductName, SKU, UnitPrice, StockQuantity, LastUpdated)
    SELECT
        'TestProd_' + CAST(ABS(CHECKSUM(NEWID())) % 1000000 AS VARCHAR(10)),
        'TSK-' + REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''),
        CAST(ABS(CHECKSUM(NEWID())) % 5000 + 1 AS DECIMAL(10,2)),
        ABS(CHECKSUM(NEWID())) % 1000,
        DATEADD(SECOND, -(ABS(CHECKSUM(NEWID())) % 8640000), SYSDATETIME())
    FROM Numbers
    WHERE @Inserted + n <= @MaxRecords;

    SET @Inserted += @BatchSize;

    IF @Inserted % 10000 = 0
        RAISERROR('Inserted %d rows...', 0, 1, @Inserted) WITH NOWAIT;
END

PRINT 'Mass insert complete: ' + CAST(@Inserted AS VARCHAR(10)) + ' rows.';
GO


-- ---- Check index fragmentation ----
SELECT
    OBJECT_NAME(ps.object_id)       AS table_name,
    i.name                           AS index_name,
    i.type_desc                      AS index_type,
    ps.avg_fragmentation_in_percent  AS frag_pct,
    ps.page_count,
    ps.avg_page_space_used_in_percent AS page_fill_pct,
    ps.record_count
FROM sys.dm_db_index_physical_stats(
        DB_ID(), OBJECT_ID('dbo.Products'), NULL, NULL, 'SAMPLED') AS ps
JOIN sys.indexes AS i
    ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE ps.page_count > 0
ORDER BY ps.avg_fragmentation_in_percent DESC;
GO

/*
  Remediation guidelines:
    frag_pct 5-30%   → ALTER INDEX ... REORGANIZE   (online, minimal locking)
    frag_pct > 30%   → ALTER INDEX ... REBUILD       (heavier, but more thorough)
*/

-- ---- Rebuild / Reorganize examples ----
-- ALTER INDEX IX_Products_ProductName ON dbo.Products REORGANIZE;
-- ALTER INDEX IX_Products_ProductName ON dbo.Products REBUILD WITH (ONLINE = ON);  -- Enterprise only
-- ALTER INDEX ALL ON dbo.Products REBUILD;
GO


-- ============================================================================
-- 4. CLEANUP (optional)
-- ============================================================================
USE master;
GO

IF DB_ID('StoreDB') IS NOT NULL
BEGIN
    ALTER DATABASE StoreDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE StoreDB;
    PRINT 'StoreDB dropped.';
END
GO
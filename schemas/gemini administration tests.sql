--Okay, let's create a generic database and the requested SQL queries. We'll use a simple StoreDB with a Products table.

--Setup: Create Database and Table

--First, run this setup script once:

-- 0. Create and Use the Database
IF DB_ID('StoreDB') IS NULL
BEGIN
    CREATE DATABASE StoreDB;
    PRINT 'Database StoreDB created.';
END
GO

USE StoreDB;
GO

-- Drop table if it exists to start fresh
IF OBJECT_ID('dbo.Products', 'U') IS NOT NULL
BEGIN
    DROP TABLE dbo.Products;
    PRINT 'Table Products dropped.';
END
GO

-- Create Products Table
CREATE TABLE dbo.Products (
    ProductID INT PRIMARY KEY IDENTITY(1,1),
    ProductName VARCHAR(255) NOT NULL,
    SKU VARCHAR(50) UNIQUE NOT NULL,
    UnitPrice DECIMAL(10, 2) NOT NULL,
    StockQuantity INT NOT NULL,
    LastUpdated DATETIME DEFAULT GETDATE()
);
PRINT 'Table Products created.';
GO

-- Create a Non-Clustered Index for fragmentation testing
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Products_ProductName' AND object_id = OBJECT_ID('dbo.Products'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Products_ProductName ON dbo.Products(ProductName);
    PRINT 'Index IX_Products_ProductName created.';
END
GO


-- Insert some initial data
INSERT INTO dbo.Products (ProductName, SKU, UnitPrice, StockQuantity)
VALUES
('Laptop Pro X', 'LPX-001', 1200.00, 50),
('Wireless Mouse G', 'WMG-002', 25.50, 200),
('Mechanical Keyboard Z', 'MKZ-003', 75.00, 100),
('4K Monitor Ultra', '4KM-004', 350.00, 30),
('Webcam HD Plus', 'WHP-005', 49.99, 150);

PRINT 'Initial data inserted into Products table.';
GO

SELECT * FROM dbo.Products;
GO


--Now, for the specific query scenarios:

--1) Two Queries to Test Blocked Sessions

--You'll need two separate query windows (sessions) in SQL Server Management Studio (SSMS) or your preferred SQL client.

--Session 1: The Update Transaction (The Blocker)

-- SESSION 1: THE BLOCKER (Update Transaction)
USE StoreDB;
GO

BEGIN TRANSACTION;

-- Update a specific product's stock quantity
-- This will acquire an exclusive lock (X) on the row where ProductID = 1
PRINT 'Session 1: Updating ProductID = 1...';
UPDATE dbo.Products
SET StockQuantity = StockQuantity - 1,
    LastUpdated = GETDATE()
WHERE ProductID = 1;

PRINT 'Session 1: ProductID = 1 updated. StockQuantity potentially changed.';
SELECT ProductID, ProductName, StockQuantity, LastUpdated
FROM dbo.Products
WHERE ProductID = 1;

-- Hold the transaction open for a bit to allow Session 2 to try and read
PRINT 'Session 1: Holding transaction open for 30 seconds...';
WAITFOR DELAY '00:00:30';

-- Now, either commit or rollback. For testing, rollback is often preferred.
PRINT 'Session 1: Rolling back transaction.';
ROLLBACK TRANSACTION;
-- COMMIT TRANSACTION; -- Alternatively, commit

PRINT 'Session 1: Transaction finished.';
SELECT ProductID, ProductName, StockQuantity, LastUpdated
FROM dbo.Products
WHERE ProductID = 1;
GO

--Session 2: The Select Query (The Blocked)

--Run this in a different query window after starting the transaction in Session 1, but before the WAITFOR DELAY in Session 1 finishes.

-- SESSION 2: THE BLOCKED (Select Query)
USE StoreDB;
GO

PRINT 'Session 2: Attempting to select ProductID = 1...';
-- This query will attempt to acquire a shared lock (S) or similar
-- on the row where ProductID = 1. It will be blocked by Session 1's exclusive lock.
SELECT ProductID, ProductName, StockQuantity, LastUpdated
FROM dbo.Products -- WITH (READPAST) -- Uncomment to skip locked rows
WHERE ProductID = 1;

PRINT 'Session 2: Select query completed (after Session 1 released its lock).';
GO

-- You can check for blocked sessions using:
-- EXEC sp_who2;
-- Or more detailed:
/*
SELECT
    blocking_session.session_id AS blocking_session_id,
    blocked_session.session_id AS blocked_session_id,
    blocking_sql.text AS blocking_sql_text,
    blocked_sql.text AS blocked_sql_text,
    wait_info.wait_type,
    wait_info.wait_duration_ms
FROM sys.dm_exec_requests AS blocked_session
INNER JOIN sys.dm_exec_connections AS blocked_connection
    ON blocked_session.session_id = blocked_connection.session_id
CROSS APPLY sys.dm_exec_sql_text(blocked_connection.most_recent_sql_handle) AS blocked_sql
INNER JOIN sys.dm_exec_requests AS blocking_session
    ON blocked_session.blocking_session_id = blocking_session.session_id
INNER JOIN sys.dm_exec_connections AS blocking_connection
    ON blocking_session.session_id = blocking_connection.session_id
CROSS APPLY sys.dm_exec_sql_text(blocking_connection.most_recent_sql_handle) AS blocking_sql
INNER JOIN sys.dm_os_waiting_tasks AS wait_info
    ON blocked_session.session_id = wait_info.session_id
WHERE blocked_session.blocking_session_id <> 0;
*/


--How to test blocking:

--Run the code in Session 1 up to and including the UPDATE statement.

--Quickly switch to Session 2 and run its SELECT statement.

--Session 2 will appear to hang or execute indefinitely.

--Wait for the WAITFOR DELAY in Session 1 to complete, and then the ROLLBACK TRANSACTION (or COMMIT) will execute.

--Session 2 will then immediately complete its SELECT statement.

--2) Two Queries that Will Deadlock Each Other

--Again, you'll need two separate query windows (sessions).

Session 1: Deadlock Participant A

-- SESSION 1: DEADLOCK PARTICIPANT A
USE StoreDB;
GO

BEGIN TRANSACTION DeadlockVictimA;

-- Lock ProductID = 2 first
PRINT 'Session 1: Updating ProductID = 2 (Acquiring lock on ProductID = 2)';
UPDATE dbo.Products
SET UnitPrice = UnitPrice + 0.01
WHERE ProductID = 2;
PRINT 'Session 1: ProductID = 2 locked.';

-- Wait for a moment to allow Session 2 to lock ProductID = 3
WAITFOR DELAY '00:00:05';

-- Now try to lock ProductID = 3 (which Session 2 will be holding)
PRINT 'Session 1: Attempting to update ProductID = 3 (Requesting lock on ProductID = 3)';
UPDATE dbo.Products
SET UnitPrice = UnitPrice + 0.01
WHERE ProductID = 3;
PRINT 'Session 1: ProductID = 3 locked (or deadlock occurred).';

COMMIT TRANSACTION DeadlockVictimA;
PRINT 'Session 1: Transaction committed (if not a deadlock victim).';
GO


--Session 2: Deadlock Participant B

--Run this in a different query window after starting the transaction in Session 1 and it has locked ProductID = 2.

-- SESSION 2: DEADLOCK PARTICIPANT B
USE StoreDB;
GO

BEGIN TRANSACTION DeadlockVictimB;

-- Lock ProductID = 3 first
PRINT 'Session 2: Updating ProductID = 3 (Acquiring lock on ProductID = 3)';
UPDATE dbo.Products
SET StockQuantity = StockQuantity - 1
WHERE ProductID = 3;
PRINT 'Session 2: ProductID = 3 locked.';

-- Wait for a moment (optional, but helps coordinate if running manually)
-- WAITFOR DELAY '00:00:01';

-- Now try to lock ProductID = 2 (which Session 1 will be holding)
PRINT 'Session 2: Attempting to update ProductID = 2 (Requesting lock on ProductID = 2)';
UPDATE dbo.Products
SET StockQuantity = StockQuantity - 1
WHERE ProductID = 2;
PRINT 'Session 2: ProductID = 2 locked (or deadlock occurred).';

COMMIT TRANSACTION DeadlockVictimB;
PRINT 'Session 2: Transaction committed (if not a deadlock victim).';
GO


--How to test deadlock:

--Run Session 1's code up to and including its first UPDATE (locks ProductID = 2).

--Quickly switch to Session 2 and run its code up to and including its first UPDATE (locks ProductID = 3).

--Allow Session 1's WAITFOR DELAY to complete. Session 1 will then attempt its second UPDATE (on ProductID = 3) and will block, waiting for Session 2 to release its lock on ProductID = 3.

--Allow Session 2 to proceed to its second UPDATE (on ProductID = 2). It will attempt to acquire a lock on ProductID = 2, which is held by Session 1.

--At this point, SQL Server will detect the deadlock. One of the sessions (the "deadlock victim") will be terminated with error message 1205 ("Transaction (Process ID XX) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction."). The other session will complete successfully.

--3) A WHILE Loop to Insert Random Data (for Index Fragmentation)

--This script will insert a large number of rows with somewhat random data, which can lead to index fragmentation, especially on non-clustered indexes or on clustered indexes if inserts are not perfectly sequential (though IDENTITY helps the clustered index).

-- 3. WHILE LOOP FOR INDEX FRAGMENTATION
USE StoreDB;
GO

DECLARE @Counter INT = 0;
DECLARE @MaxRecords INT = 50000; -- Insert 50,000 records, adjust as needed
DECLARE @BatchSize INT = 1000; -- Commit in batches
DECLARE @ProductNameBase VARCHAR(50) = 'Test Product ';
DECLARE @SKUBase VARCHAR(20) = 'TESTSKU-';

PRINT 'Starting data insertion loop...';

WHILE @Counter < @MaxRecords
BEGIN
    IF @Counter % @BatchSize = 0 AND @Counter > 0
    BEGIN
        PRINT 'Inserted ' + CAST(@Counter AS VARCHAR(10)) + ' records so far...';
        -- Consider a small delay or checkpoint if inserting millions to reduce log pressure
        -- CHECKPOINT;
        -- WAITFOR DELAY '00:00:01';
    END

    BEGIN TRANSACTION;
    -- Insert a small batch within the transaction for slightly better performance than row-by-row commit
    DECLARE @InnerCounter INT = 0;
    WHILE @InnerCounter < 10 AND (@Counter + @InnerCounter) < @MaxRecords -- Insert 10 records per mini-batch
    BEGIN
        INSERT INTO dbo.Products (ProductName, SKU, UnitPrice, StockQuantity, LastUpdated)
        VALUES (
            @ProductNameBase + CAST(ABS(CHECKSUM(NEWID())) % 1000000 AS VARCHAR(10)), -- More varied names
            @SKUBase + REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''), -- Ensure unique SKU
            CAST(ABS(CHECKSUM(NEWID())) % 5000 AS DECIMAL(10,2)) + 0.01, -- Random price > 0
            ABS(CHECKSUM(NEWID())) % 1000, -- Random stock
            DATEADD(SECOND, -(ABS(CHECKSUM(NEWID())) % 8640000), GETDATE()) -- Random date in last 100 days
        );
        SET @InnerCounter = @InnerCounter + 1;
    END
    COMMIT TRANSACTION;

    SET @Counter = @Counter + @InnerCounter;
END

PRINT 'Finished inserting ' + CAST(@Counter AS VARCHAR(10)) + ' records.';
GO

-- Check for Index Fragmentation
-- You may need to run this a few times as background processes complete
PRINT 'Checking index fragmentation...';
SELECT
    DB_NAME(ps.database_id) AS DatabaseName,
    OBJECT_NAME(ps.OBJECT_ID) AS TableName,
    i.name AS IndexName,
    ips.index_type_desc,
    ps.avg_fragmentation_in_percent,
    ps.page_count,
    ps.avg_page_space_used_in_percent,
    ps.record_count,
    ps.forwarded_record_count -- Relevant for heaps
FROM sys.dm_db_index_physical_stats (DB_ID('StoreDB'), OBJECT_ID('dbo.Products'), NULL, NULL, 'SAMPLED') AS ps -- Use 'DETAILED' for more accuracy but slower
INNER JOIN sys.indexes AS i
    ON ps.OBJECT_ID = i.OBJECT_ID AND ps.index_id = i.index_id
INNER JOIN sys.dm_db_partition_stats AS ips
    ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ps.avg_fragmentation_in_percent > 5 -- Show indexes with more than 5% fragmentation
ORDER BY ps.avg_fragmentation_in_percent DESC;
GO


--Explanation of Fragmentation Test:

--The loop inserts many records. The ProductName is varied, and SKU is unique using NEWID().

--IX_Products_ProductName (non-clustered index) will likely show significant fragmentation because new product names are inserted in a non-sequential order relative to the index key. This causes page splits.

--The Clustered Index (on ProductID, which is an IDENTITY) will experience less fragmentation from these inserts because IDENTITY values are sequential. However, if you were to DELETE rows from the middle and then insert --more, or UPDATE rows causing them to grow and not fit on their page, the clustered index would also fragment.

--The sys.dm_db_index_physical_stats DMV is used to check the fragmentation levels. avg_fragmentation_in_percent is the key metric.

--Cleanup (Optional)

--If you want to remove the database after testing:

-- CLEANUP (Optional)
USE master;
GO
IF DB_ID('StoreDB') IS NOT NULL
BEGIN
    ALTER DATABASE StoreDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE StoreDB;
    PRINT 'Database StoreDB dropped.';
END
GO

--Remember to run the session-specific queries in separate windows and in the correct order to observe the blocking and deadlocking behaviors.
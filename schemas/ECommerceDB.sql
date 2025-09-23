use ECommerceDB--Build Schema--CREATE TABLE Customers (--    CustomerID INT PRIMARY KEY,--    Email VARCHAR(100) MASKED WITH (FUNCTION = 'email()'),--    LastPurchaseDate DATETIME--);--CREATE TABLE Products (--    ProductID INT PRIMARY KEY,--    Name VARCHAR(100),--    Price DECIMAL(10,2),--    Stock INT CHECK (Stock >= 0)--);-- Add indexesCREATE NONCLUSTERED INDEX IX_Orders_CustomerID ON Orders(CustomerID);


--	3. Generate Test Data
--		○ Use T-SQL loops or PowerShell to insert 1M+ rows.
--		○ Example:CREATE TABLE Orders (
OrderID INT IDENTITY(1,1) PRIMARY KEY,
CustomerID INT NOT NULL,
OrderDate DATE NOT NULL,
Amount DECIMAL(18,2) NOT NULL
);INSERT INTO Orders (CustomerID, OrderDate, Amount)SELECT     ABS(CHECKSUM(NEWID()) % 10000) + 1, -- Random CustomerID    DATEADD(day, RAND() * 365, '2023-01-01'), -- Random date in 2023    RAND() * 1000 -- Random amountFROM master..spt_valuesWHERE type = 'P' AND number < 1000000; -- 1M rows



--	4. Tune Performance
	--	○ Find slow queries:SELECT TOP 10     qs.execution_count,    qt.text AS query_text,    qp.query_planFROM sys.dm_exec_query_stats qsCROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qtCROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qpORDER BY qs.total_logical_reads DESC;


--Add missing indexes suggested by DMVs.
	--5. Automate Backups
		--○ Create a SQL Agent job for transaction log backups:BACKUP LOG ECommerceDB TO DISK = 'C:\Backups\ECommerceDB_Log.trn';


	--6. Simulate Recovery
		--○ Restore a dropped table:RESTORE DATABASE ECommerceDB FROM DISK = 'C:\Backups\ECommerceDB_Full.bak'WITH NORECOVERY;RESTORE LOG ECommerceDB FROM DISK = 'C:\Backups\ECommerceDB_Log.trn'WITH STOPAT = '2023-10-05 12:00:00', RECOVERY;

	--7. Audit Security
		--○ Track access to customer data:CREATE SERVER AUDIT CustomerDataAuditTO FILE (FILEPATH = 'C:\Audit\');ALTER DATABASE AUDIT SPECIFICATION AuditCustomerSelectADD (SELECT ON Customers BY PUBLIC);

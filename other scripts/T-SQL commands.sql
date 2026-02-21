/* =========================================================================
   SQL SERVER T-SQL COMMANDS AND FUNCTIONS - REFERENCE GUIDE
   =========================================================================
   
   This file contains a comprehensive collection of SQL Server commands,
   functions, and techniques organized by category for easy reference.
   
   Table of Contents:
   1. DATA TYPE CONVERSION FUNCTIONS
   2. STRING FUNCTIONS
   3. DATE AND TIME FUNCTIONS
   4. WINDOW FUNCTIONS
   5. QUERY OPERATIONS AND TECHNIQUES
   6. JOINS
   7. SET OPERATIONS
   8. UPDATE OPERATIONS
   9. STORED PROCEDURES
   10. USER-DEFINED FUNCTIONS
   11. TEMPORARY TABLES
   12. INDEXES
   13. TRIGGERS
   14. CTEs AND DERIVED TABLES
   15. TRANSACTIONS AND ISOLATION LEVELS
   16. ERROR HANDLING
   17. CURSORS
   18. BULK OPERATIONS
   19. TABLE CREATION EXAMPLES
   
========================================================================= */


/* =========================================================================
   1. DATA TYPE CONVERSION FUNCTIONS
========================================================================= */

-- CAST: Change datatype into the specified type
-- Usage: Converts a single value or cell to another datatype
SELECT * FROM table WHERE CAST(num AS BIGINT) = 155555555555;

-- CONVERT: Convert an entire column to a different datatype
-- More flexible than CAST, allows format specification for dates
SELECT CONVERT(BIGINT, [num]) FROM [table];

-- ROUND: Round numeric values to specified precision
-- Second argument specifies the number of decimal places
-- Note: Not very useful for databases that don't deal with float computations
SELECT ROUND(123.918392, 3); -- Returns 123.918


/* =========================================================================
   2. STRING FUNCTIONS
========================================================================= */

-- LEFT: Returns specified number of characters from the left side
SELECT LEFT('ABCDE', 3); -- Returns 'ABC'

-- RIGHT: Returns specified number of characters from the right side
SELECT RIGHT('ABCDE', 3); -- Returns 'CDE'

-- LTRIM: Remove leading spaces
SELECT LTRIM('   Hello'); -- Returns 'Hello'

-- RTRIM: Remove trailing spaces
SELECT RTRIM('Hello   '); -- Returns 'Hello'

-- LOWER: Convert to lowercase
SELECT LOWER('CONVERT This String Into Lower Case');

-- UPPER: Convert to uppercase
SELECT UPPER('convert this to upper');

-- REVERSE: Reverse a string
SELECT REVERSE('ABCDEFGHIJKLMNOPQRSTUVWXYZ');

-- LEN: Get the length of a string (excludes trailing spaces)
SELECT LEN('SQL Functions   '); -- Returns 13

-- SUBSTRING: Extract a portion of a string
-- SUBSTRING(string, start_position, length)
SELECT SUBSTRING(num, 3, 6) FROM example_table;
SELECT num FROM example_table WHERE SUBSTRING(num, 3, 6) = '222222';

-- CHARINDEX: Find the position of a substring within a string
-- CHARINDEX(search_string, string, start_location)
SELECT CHARINDEX('@', 'sara@aaa.com', 1); -- Returns position of @

-- REPLACE: Replace all occurrences of a substring with another string
SELECT REPLACE(num, 'Ahmad', 'AHMAD') FROM table WHERE num = '1234';

-- REPLICATE: Repeat a string a specified number of times
SELECT REPLICATE('Pragim', 3); -- Returns 'PragimPragimPragim'

-- Example: Combining string functions to mask email addresses
SELECT FirstName, 
       LastName, 
       SUBSTRING(Email, 1, 2) + REPLICATE('*', 5) + 
       SUBSTRING(Email, CHARINDEX('@', Email), LEN(Email) - CHARINDEX('@', Email) + 1) AS Email
FROM tblEmployee;


/* =========================================================================
   3. DATE AND TIME FUNCTIONS
========================================================================= */

-- DAY: Extract day from a date
SELECT DAY(GETDATE()); -- Returns day number of the month

-- MONTH: Extract month from a date
SELECT MONTH(GETDATE()); -- Returns month number

-- YEAR: Extract year from a date
SELECT YEAR(GETDATE()); -- Returns year

-- DATENAME: Returns a string representing a part of the date
SELECT DATENAME(Day, '2012-09-30 12:43:46.837'); -- Returns '30'

-- ISDATE: Check if a value is a valid date (returns 1 for valid, 0 for invalid)
SELECT ISDATE(GETDATE()); -- Returns 1

-- GETDATE: Returns current system date and time
SELECT GETDATE();

-- DATEDIFF: Calculate difference between two dates
SELECT DATEDIFF(YEAR, '2000-01-01', GETDATE());


/* =========================================================================
   4. WINDOW FUNCTIONS
========================================================================= */

-- ROW_NUMBER: Assigns sequential row numbers
-- Useful for pagination and ranking
SELECT ROW_NUMBER() OVER (ORDER BY PKID) AS num,
       *
FROM [example_table];

-- RANK: Similar to ROW_NUMBER but assigns same rank to duplicate values
-- Leaves gaps in ranking sequence after duplicates
SELECT RANK() OVER (ORDER BY [UnitPrice] DESC) AS PriceRank,
       [ProductID],
       [Name],
       [SupplierID],
       [CategoryID],
       [SubCategoryID],
       [QuantityPerUnit],
       [UnitPrice],
       [OldPrice],
       [UnitWeight],
       [Size],
       [Discount],
       [UnitInStock],
       [UnitOnOrder],
       [ProductAvailable],
       [ImageURL],
       [AltText],
       [AddBadge],
       [OfferTitle],
       [OfferBadgeClass],
       [ShortDescription],
       [LongDescription]
FROM [Kahreedo].[dbo].[Products];


/* =========================================================================
   5. QUERY OPERATIONS AND TECHNIQUES
========================================================================= */

-- CASE: Conditional logic in SQL
-- Very useful for conditional transformations
SELECT [num],
       [AccountTitle],
       Mandate = CASE [MandateType]
                    WHEN '0' THEN 'Any'
                    WHEN '2' THEN 'All'
                    ELSE 'Custom'
                 END,
       [CreatedDate],
       [CreatedBy]
FROM [example_table];

-- SELECT INTO: Create a new table from query results
-- Note: New table will be created without constraints and indexes
SELECT * INTO newtable2 FROM exampletable;

-- GROUP BY with HAVING: Aggregate data and filter groups
-- Very useful for finding duplicates and aggregating data
-- HAVING clause filters results after grouping
SELECT num, COUNT(*)
FROM accounts
GROUP BY num
HAVING COUNT(*) > 1; -- Find duplicate account numbers

-- PIVOT: Transform rows into columns
-- Rotates a table by turning unique values from one column into multiple columns
SELECT [ProductID], [Polo T-Shirt], [New Polo T-Shirt] 
FROM [Products]
PIVOT (
    SUM(unitinstock) 
    FOR [Name] IN ([Polo T-Shirt], [New Polo T-Shirt])
) AS PivotTable;

-- FINDING NTH HIGHEST VALUE
-- Method 1: Using nested queries
SELECT TOP 1 Salary, FirstName 
FROM (
    SELECT DISTINCT TOP (3) [Salary], [FirstName], [LastName], [Gender]
    FROM [TestingApplication].[dbo].[Employees] 
    ORDER BY Salary DESC
) result
ORDER BY Salary;

-- Method 2: Using OFFSET-FETCH (more efficient)
SELECT *
FROM example_table
ORDER BY num DESC
OFFSET 3 ROWS
FETCH NEXT 1 ROWS ONLY;

-- COALESCE: Return first non-NULL value from a list
-- Useful for handling NULL values and providing defaults
SELECT [EMPLOYEE_ID],
       COALESCE([FIRST_NAME], [LAST_NAME], [EMAIL]) AS Name
FROM [EMPLOYEES];


/* =========================================================================
   6. JOINS
========================================================================= */

-- SELF JOIN: Join a table with itself
-- Useful when hierarchical or relational data exists within the same table
-- Example: Employees and their managers in the same table
SELECT a.[EMPLOYEE_ID],
       a.FIRST_NAME + ' ' + a.LAST_NAME AS EMPLOYEE_NAME,
       a.MANAGER_ID,
       b.FIRST_NAME + ' ' + b.LAST_NAME AS MANAGER_NAME
FROM [HR].[dbo].[EMPLOYEES] a 
LEFT JOIN EMPLOYEES b ON a.MANAGER_ID = b.EMPLOYEE_ID;


/* =========================================================================
   7. SET OPERATIONS
========================================================================= */

-- UNION and UNION ALL: Combine results from multiple SELECT statements
-- UNION removes duplicate rows (slower - requires distinct sort)
-- UNION ALL keeps all rows including duplicates (faster)
-- Requirements: Same number of columns with compatible data types
-- Difference from JOINS: UNION combines rows, JOINS combine columns

-- UNION (removes duplicates)
SELECT Id, Name, Email FROM tblIndiaCustomers
UNION
SELECT Id, Name, Email FROM tblUKCustomers
ORDER BY Name; -- ORDER BY must be on the last SELECT statement

-- UNION ALL (keeps duplicates)
SELECT Id, Name, Email FROM tblIndiaCustomers
UNION ALL
SELECT Id, Name, Email FROM tblUKCustomers;


/* =========================================================================
   8. UPDATE OPERATIONS
========================================================================= */

-- Basic UPDATE with REPLACE
-- Used to replace a portion of a specific value
-- Example: Convert lowercase to uppercase in account numbers
UPDATE example_table 
SET num = REPLACE(num, 'Ahmad', 'AHMAD') 
WHERE num = '1234';

-- UPDATE with JOIN: Update based on data from another table
-- Very useful for bulk updates based on related data
UPDATE assets
SET trade_start_date = b.trade_start_date
FROM assets a 
INNER JOIN [EmployeeCaseStudy].[dbo].[temptable] b ON a.slug = b.slug
WHERE b.trade_start_date <> '2016-09-09';


/* =========================================================================
   9. STORED PROCEDURES
========================================================================= */

-- Basic Stored Procedure with Parameters
CREATE PROCEDURE spGetEmployeesByGenderAndDepartment 
    @ManagerId NVARCHAR(50),
    @DepartmentId INT
AS
BEGIN
    SELECT FIRST_NAME, EMAIL, PHONE_NUMBER 
    FROM EMPLOYEES 
    WHERE MANAGER_ID = @ManagerId 
      AND DEPARTMENT_ID = @DepartmentId;
END;

-- Execute stored procedure
EXECUTE spGetEmployeesByManagerAndDep @DepartmentId = 90, @ManagerId = '100';

-- Stored Procedure with OUTPUT Parameter
CREATE PROCEDURE spGetEmployeeCountByGender
    @Gender NVARCHAR(20),
    @EmployeeCount INT OUTPUT
AS
BEGIN
    SELECT @EmployeeCount = COUNT(Id) 
    FROM tblEmployee 
    WHERE Gender = @Gender;
END;

-- Call with OUTPUT parameter
DECLARE @EmployeeTotal INT;
EXECUTE spGetEmployeeCountByGender 'Female', @EmployeeTotal OUTPUT;
SELECT @EmployeeTotal;

-- Stored Procedure with RETURN Value
-- Note: RETURN should only be used with integer values
CREATE PROCEDURE spGetTotalCountOfEmployees2
AS
BEGIN
    RETURN (SELECT COUNT(ID) FROM Employees);
END;

-- Call with RETURN value
DECLARE @TotalEmployees INT;
EXECUTE @TotalEmployees = spGetTotalCountOfEmployees2;
SELECT @TotalEmployees;

-- Stored Procedure Example: Insert Employee
CREATE PROCEDURE [dbo].[Sp_AddEmployee]
    @Name NVARCHAR(50),
    @Gender NVARCHAR(20),
    @Salary INT
AS
BEGIN
    INSERT INTO [dbo].[tblEmployee] ([Name], [Gender], [Salary])
    VALUES (@Name, @Gender, @Salary);
END;


/* =========================================================================
   10. USER-DEFINED FUNCTIONS
========================================================================= */

-- 1) SCALAR FUNCTIONS
-- Returns a single value of a specific type (varchar, int, etc.)
-- Example: Calculate age or years of service
CREATE FUNCTION Age(@DOB DATE)  
RETURNS INT  
AS  
BEGIN  
    DECLARE @Age INT;
    SET @Age = DATEDIFF(YEAR, @DOB, GETDATE()) - 
               CASE WHEN (MONTH(@DOB) > MONTH(GETDATE())) OR 
                         (MONTH(@DOB) = MONTH(GETDATE()) AND DAY(@DOB) > DAY(GETDATE())) 
                    THEN 1 
                    ELSE 0 
               END;
    RETURN @Age;
END;

-- Using scalar functions in SELECT statements and WHERE clauses
SELECT [EMPLOYEE_ID],
       [FIRST_NAME],
       [LAST_NAME],
       [EMAIL],
       [PHONE_NUMBER],
       dbo.Age([HIRE_DATE]) AS 'service years'
FROM [HR].[dbo].[EMPLOYEES] 
WHERE dbo.Age([HIRE_DATE]) > 20;

-- 2) INLINE TABLE-VALUED FUNCTIONS
-- Returns a table - acts like a parameterized view
-- More efficient than multi-statement functions
CREATE FUNCTION fn_EmployeesByDepID(@DepId INT)
RETURNS TABLE
AS
RETURN (
    SELECT [EMPLOYEE_ID],
           [FIRST_NAME],
           [LAST_NAME],
           [EMAIL],
           [PHONE_NUMBER],
           [HIRE_DATE],
           [JOB_ID],
           [SALARY],
           [MANAGER_ID]
    FROM [EMPLOYEES]
    WHERE [DEPARTMENT_ID] = @DepId
);

-- Query inline function like a table
SELECT * 
FROM fn_EmployeesByDepID(90) a 
INNER JOIN JOBS b ON a.JOB_ID = b.JOB_ID;

-- Update through inline function
UPDATE fn_EmployeesByDepID(90) 
SET Phone_Number = '0798632519' 
WHERE Employee_ID = '211';

-- 3) MULTI-STATEMENT TABLE-VALUED FUNCTIONS
-- Returns a table with more complex logic
-- Allows multiple statements and variable declaration
-- Reference: https://csharp-video-tutorials.blogspot.com/2012/09/multi-statement-table-valued-functions.html
CREATE FUNCTION [dbo].[fn_GetEmployees]()
RETURNS @table TABLE (Id INT, EmpNAME VARCHAR(40), HireDate DATE)
AS
BEGIN
    INSERT INTO @table
    SELECT [EMPLOYEE_ID], 
           [FIRST_NAME] + ' ' + [LAST_NAME], 
           [HIRE_DATE]
    FROM [EMPLOYEES];
    RETURN;
END;

-- FUNCTION OPTIONS

-- Encrypting a function (prevents viewing definition)
ALTER FUNCTION [dbo].[GETID]()
RETURNS INT
WITH ENCRYPTION
AS  
BEGIN
    DECLARE @maxID INT;
    SET @maxID = (SELECT MAX([EMPLOYEE_ID]) FROM EMPLOYEES);
    RETURN @maxID + 1;
END;

-- Schema binding (prevents dropping referenced tables)
ALTER FUNCTION [dbo].[GETID]()
RETURNS INT
WITH SCHEMABINDING
AS  
BEGIN
    DECLARE @maxID INT;
    SET @maxID = (SELECT MAX([EMPLOYEE_ID]) FROM dbo.EMPLOYEES);
    RETURN @maxID + 1;
END;

-- More about functions: https://csharp-video-tutorials.blogspot.com/2012/09/important-concepts-related-to-functions.html


/* =========================================================================
   11. TEMPORARY TABLES
========================================================================= */

-- Temporary tables contain non-permanent data
-- Useful for storing intermediate results in complex queries

-- LOCAL TEMPORARY TABLES (#TableName)
-- Only visible to the current session
-- Automatically dropped when session closes
CREATE TABLE #PersonDetails(Id INT, Name NVARCHAR(20));

-- GLOBAL TEMPORARY TABLES (##TableName)
-- Visible to all sessions
-- Dropped when last connection referencing it closes
CREATE TABLE ##EmployeeDetails(Id INT, Name NVARCHAR(20));

-- Using temporary tables in stored procedures
CREATE PROCEDURE spCreateLocalTempTable
AS
BEGIN
    SELECT * INTO #LinkMonsterDetails 
    FROM MONSTERS 
    WHERE TYPE = 'Link Monster';
    
    SELECT * FROM #LinkMonsterDetails;
END;


/* =========================================================================
   12. INDEXES
========================================================================= */

-- Creating indexes for performance optimization
-- Indexes speed up data retrieval but slow down INSERT/UPDATE/DELETE

-- Simple index
CREATE INDEX ix_monsters ON [MONSTERS] (attack ASC);

-- Composite nonclustered index
CREATE NONCLUSTERED INDEX ixemployeesphones 
ON EMPLOYEES (EMPLOYEE_ID DESC, PHONE_NUMBER DESC);

-- Get information about table indexes
EXEC sp_helpindex EMPLOYEES;

-- UNIQUE INDEX with IGNORE_DUP_KEY option
-- By default, duplicate values are not allowed on key columns with unique indexes
-- IGNORE_DUP_KEY: Rejects only duplicate rows instead of entire batch
CREATE UNIQUE INDEX IX_tblEmployee_City
ON tblEmployee(City)
WITH IGNORE_DUP_KEY;


/* =========================================================================
   13. TRIGGERS
========================================================================= */

-- Triggers are special stored procedures that automatically execute
-- when an event (INSERT, UPDATE, DELETE) occurs on a table

CREATE TRIGGER [dbo].[tr_tblEMployee_ForInsert]
ON [dbo].[EMPLOYEES]
FOR INSERT
AS
BEGIN
    DECLARE @Id INT;
    SELECT @Id = EMPLOYEE_ID FROM inserted;
    
    INSERT INTO tblEmployeeAudit 
    VALUES('New employee with Id = ' + CAST(@Id AS NVARCHAR(5)) + 
           ' is added at ' + CAST(GETDATE() AS NVARCHAR(20)));
END;


/* =========================================================================
   14. CTEs AND DERIVED TABLES
========================================================================= */

-- DERIVED TABLE (Subquery in FROM clause)
-- Exists only for the duration of the query
SELECT DEPARTMENT_NAME, TotalEmployees
FROM (
    SELECT [DEPARTMENT_NAME], 
           a.[DEPARTMENT_ID], 
           COUNT(*) AS TotalEmployees
    FROM EMPLOYEES a
    JOIN DEPARTMENTS b ON a.DEPARTMENT_ID = b.DEPARTMENT_ID
    GROUP BY [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
) AS EmployeeCount
WHERE TotalEmployees >= 2;

-- COMMON TABLE EXPRESSION (CTE)
-- More readable than derived tables
-- Can be referenced multiple times in the same query
-- Supports recursion

-- CTE with column names specified
WITH EmployeeCount([DEPARTMENT_NAME], [DEPARTMENT_ID], TotalEmployees)
AS (
    SELECT [DEPARTMENT_NAME], 
           a.[DEPARTMENT_ID], 
           COUNT(*) AS TotalEmployees
    FROM EMPLOYEES a
    JOIN DEPARTMENTS b ON a.DEPARTMENT_ID = b.DEPARTMENT_ID
    GROUP BY [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
)
SELECT [DEPARTMENT_NAME], TotalEmployees
FROM EmployeeCount
WHERE TotalEmployees >= 2;

-- CTE with inferred column names (simpler syntax)
WITH EmployeeCount
AS (
    SELECT [DEPARTMENT_NAME], 
           a.[DEPARTMENT_ID], 
           COUNT(*) AS TotalEmployees
    FROM EMPLOYEES a
    JOIN DEPARTMENTS b ON a.DEPARTMENT_ID = b.DEPARTMENT_ID
    GROUP BY [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
)
SELECT [DEPARTMENT_NAME], TotalEmployees
FROM EmployeeCount
WHERE TotalEmployees >= 2;


/* =========================================================================
   15. TRANSACTIONS AND ISOLATION LEVELS
========================================================================= */

-- TRANSACTIONS
-- A transaction is a group of commands treated as a single unit
-- Ensures either all commands succeed or none of them (ACID properties)

BEGIN TRY
    BEGIN TRANSACTION;
        UPDATE tblMailingAddress 
        SET City = 'LONDON' 
        WHERE AddressId = 1 AND EmployeeNumber = 101;
        
        UPDATE tblPhysicalAddress 
        SET City = 'LONDON' 
        WHERE AddressId = 1 AND EmployeeNumber = 101;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
END CATCH;

-- TRANSACTION ISOLATION LEVELS
-- Control how transactions handle concurrency and locking

-- READ COMMITTED (default)
-- Only read data that has been committed
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- READ UNCOMMITTED (dirty reads allowed)
-- Read data that has not been committed
-- Fastest but least safe
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- REPEATABLE READ
-- Locks rows being read to prevent modifications until transaction completes
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- SNAPSHOT
-- Creates a snapshot of data; reads from snapshot instead of live data
-- Prevents blocking but uses more tempdb space
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;

-- SERIALIZABLE (highest isolation)
-- Strongest isolation; prevents phantom reads
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Check current isolation level
SELECT transaction_sequence_num,
       commit_sequence_num,
       is_snapshot,
       t.session_id,
       first_snapshot_sequence_num,
       max_version_chain_traversed,
       elapsed_time_seconds,
       host_name,
       login_name,
       CASE transaction_isolation_level
           WHEN '0' THEN 'Unspecified'
           WHEN '1' THEN 'ReadUncomitted'
           WHEN '2' THEN 'ReadCommitted'
           WHEN '3' THEN 'Repeatable'
           WHEN '4' THEN 'Serializable'
           WHEN '5' THEN 'Snapshot'
       END AS transaction_isolation_level
FROM sys.dm_tran_active_snapshot_database_transactions t
JOIN sys.dm_exec_sessions s ON t.session_id = s.session_id;


/* =========================================================================
   16. ERROR HANDLING
========================================================================= */

-- TRY-CATCH blocks for error handling in SQL Server 2005+
-- Reference: https://csharp-video-tutorials.blogspot.com/2012/10/error-handling-in-sql-server-2000-part.html
-- Reference: https://csharp-video-tutorials.blogspot.com/2012/10/error-handling-in-sql-server-2005-and_6.html

BEGIN TRY
    -- Code that might cause an error
    SELECT 1/0;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,
           ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState,
           ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine,
           ERROR_MESSAGE() AS ErrorMessage;
END CATCH;


/* =========================================================================
   17. CURSORS
========================================================================= */

-- Cursors allow row-by-row processing of result sets
-- Use sparingly - set-based operations are usually more efficient

DECLARE @userFk UNIQUEIDENTIFIER;

DECLARE crsr CURSOR FOR 
    SELECT objectid FROM AppSetting;

OPEN crsr;
FETCH NEXT FROM crsr INTO @userFk;

WHILE (@@FETCH_STATUS = 0)
BEGIN
    PRINT @userFk;
    FETCH NEXT FROM crsr INTO @userFk;
END;

CLOSE crsr;
DEALLOCATE crsr;


/* =========================================================================
   18. BULK OPERATIONS
========================================================================= */

-- BULK INSERT: Import data from a file
-- Fast way to load large amounts of data
BULK INSERT dbo.Actors
FROM 'C:\Documents\Skyvia\csv-to-mssql\actor.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2
);
GO


/* =========================================================================
   19. TABLE CREATION EXAMPLES
========================================================================= */

-- Example table with identity column and constraints
CREATE TABLE [dbo].[tblEmployee](
    [ID] [INT] IDENTITY(1,1) NOT NULL,
    [Name] [NVARCHAR](50) NULL,
    [Gender] [NVARCHAR](50) NULL,
    [Salary] [NVARCHAR](50) NULL,
    PRIMARY KEY CLUSTERED ([ID] ASC)
    WITH (
        PAD_INDEX = OFF, 
        STATISTICS_NORECOMPUTE = OFF, 
        IGNORE_DUP_KEY = OFF, 
        ALLOW_ROW_LOCKS = ON, 
        ALLOW_PAGE_LOCKS = ON, 
        OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF
    ) ON [PRIMARY]
) ON [PRIMARY];
GO





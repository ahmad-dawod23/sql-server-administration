
--sql server commands and functions cheat sheet

-- cast:
--change datatype into the specficed type
SELECT * FROM table where cast(num as bigint)=155555555555
-- convert:
-- convert is used whenever you want to convert an entire colume as opposed to cast which only changes a single value (or cell) to another datatype
-- the below query will change the entire column to a big int type instead of varchar
-- it can also be used in a where condition
SELECT convert (bigint, [num]) FROM [table]
-- round: 
-- second argument of the function specfies the length of the round
--not very useful for our work as we dont deal with float numbers and computations on a db level in our products
select round(123.918392, 3)




---string functions:

--Returns the specified number of characters from the left hand side of the given character expression.
Select LEFT('ABCDE', 3)
--Returns the specified number of characters from the right hand side of the given character expression.
Select RIGHT('ABCDE', 3)
--left side space removal
Select LTRIM('   Hello')
--right side space removal:
Select RTRIM('Hello   ')
--convert upper case to lower case:
Select LOWER('CONVERT This String Into Lower Case')
---reverse a string 
Select REVERSE('ABCDEFGHIJKLMNOPQRSTUVWXYZ')
--outputs the total number characters in a string
Select LEN('SQL Functions   ')
-- extract a substring that starts from the first parameter and goes for the length of the second parameter:
select substring(num, 3,6) from example_table
select num from example_table where substring(num,3,6)='222222'
--Returns the starting position of the specified expression in a character string. Start_Location parameter is optional.
Select CHARINDEX('@','sara@aaa.com',1)
---replace: its used to replace a portion of specfic value
Select * REPLACE(num, 'Nbksigcap','NBKSIGCAP') Where num = 'Nbksigcap12042'
---replicate: Repeats the given string, for the specified number of times.
SELECT REPLICATE('Pragim', 3)
    

--date functions:

Select DAY(GETDATE()) -- Returns the day number of the month, based on current system datetime.
Select Month(GETDATE()) -- Returns the Month number of the year, based on the current system date and time
Select Year(GETDATE()) -- Returns the year
Select DATENAME(Day, '2012-09-30 12:43:46.837') -- Returns a string, that represents a part of the given date. This functions takes 2 parameters. which in this case is 30
--ISDATE() - Checks if the given value, is a valid date, time, or datetime. Returns 1 for success, 0 for failure.
Select ISDATE(Getdate()) -- returns 1

--using them all in one query:
Select FirstName, LastName, SUBSTRING(Email, 1, 2) + REPLICATE('*',5) + 
SUBSTRING(Email, CHARINDEX('@',Email), LEN(Email) - CHARINDEX('@',Email)+1) as Email
from tblEmployee



--case:
-- very useful
SELECT [num]
      ,[AccountTitle]
      ,Mandate = case [MandateType]
	  when '0' then 'Any'
	  when '2' then 'All'
	  else 'Custom'
	  end
      ,[CreatedDate]
      ,[CreatedBy]
  FROM [example_table]



--row number:
--can be useful in some situations

SELECT ROW_NUMBER() OVER (ORDER BY PKID) AS num,
FROM [example_table]


--rank function
--can be used just like row number, but its better in the fact that it can filter same values with the same rank

SELECT rank() over (order by [UnitPrice] desc) as PriceRank
	,[ProductID]
      ,[Name]
      ,[SupplierID]
      ,[CategoryID]
      ,[SubCategoryID]
      ,[QuantityPerUnit]
      ,[UnitPrice]
      ,[OldPrice]
      ,[UnitWeight]
      ,[Size]
      ,[Discount]
      ,[UnitInStock]
      ,[UnitOnOrder]
      ,[ProductAvailable]
      ,[ImageURL]
      ,[AltText]
      ,[AddBadge]
      ,[OfferTitle]
      ,[OfferBadgeClass]
      ,[ShortDescription]
      ,[LongDescription]
  FROM [Kahreedo].[dbo].[Products]


-- select into:
-- note that the new table will be created with no constrains and indexes 
-- very useful
select * into newtable2 from exampletable
  


-- group by
-- very useful to group row elements to a single value like account number and using an aggreagite function with it
-- the below example will find repeated account titles if they exist
-- having is a condition that is used with group by, it will apply its condition after the grouping has been made
select num, count(*)
from accounts
group by num
having count(*)>1



--pivot
--Pivot is a sql server operator that can be used to turn unique values from one column, into multiple columns in the output, there by effectively rotating a table.
   select [ProductID],[Polo T-Shirt],[New Polo T-Shirt] from [Products]
 pivot
  (
  sum(unitinstock) for [Name] in ([Polo T-Shirt],[New Polo T-Shirt])
  ) 
  as PivotTable


-- How to find nth highest value:
select top 1 Salary, FirstName from (
SELECT distinct top (3)
 [Salary],
 [FirstName],
 [LastName],
 [Gender]
FROM [TestingApplication].[dbo].[Employees] order by Salary desc) result
order by Salary
--another way to find it:

SELECT *
FROM example_table
ORDER BY num DESC
OFFSET 3 rows
fetch next 1 rows only




--self join: can be used to join a table with itself, in the below example from the sample hr schema
-- both the, EMPLOYEE and MANAGER rows, are present in the same table
-- to not confuse ourselves, we can pretend that the second table is a different table altogether and join with it based on the forgin key (in this case the manager id)
-- and retrieve columns from it based on its aliace.
SELECT a.[EMPLOYEE_ID]
      ,a.FIRST_NAME+' '+a.LAST_NAME as EMPLOYEE_NAME
	  ,a.MANAGER_ID
	  ,b.FIRST_NAME+' '+b.LAST_NAME as MANAGER_NAME
  FROM [HR].[dbo].[EMPLOYEES] a left join EMPLOYEES b on a.MANAGER_ID=b.EMPLOYEE_ID



--Coalesce() function
-- The COALESCE() function returns only the first non null value from the 3 columns.
--We are passing FirstName, MiddleName and LastName columns as parameters to the COALESCE() function.

SELECT [EMPLOYEE_ID]
      ,COALESCE([FIRST_NAME],[LAST_NAME],[EMAIL])
  FROM [EMPLOYEES]
  
  
--update

--update with join:

UPDATE 
    assets
SET 
trade_start_date=b.trade_start_date
FROM 
   assets a inner join [EmployeeCaseStudy].[dbo].[temptable] b on a.slug=b.slug
WHERE 
b.trade_start_date<>'2016-09-09'
  
  
---update with replace
--- its used to replace a portion of specfic value
--- in the below example, its used in a update statement inorder to change the account number from using lower case letters to upper case letters(real use case)
Update example_table Set num = REPLACE(num, 'Nbksigcap','NBKSIGCAP') Where num = 'Nbksigcap12042'




---union
---UNION and UNION ALL operators in SQL Server, are used to combine the result-set of two or more SELECT queries.
---UNION removes duplicate rows, where as UNION ALL does not. 
--When use UNION, to remove the duplicate rows, sql server has to to do a distinct sort, which is time consuming. 
--For this reason, UNION ALL is much faster than UNION. 
--unions only work with matching datatypes and columns
--If you want to sort, the results of UNION or UNION ALL, the ORDER BY caluse should be used on the last SELECT statement as shown below.
--difference between unions and joins: UNION combines rows from 2 or more tables, where JOINS combine columns from 2 or more table.
Select Id, Name, Email from tblIndiaCustomers
UNION
Select Id, Name, Email from tblUKCustomers
Order by Name








--stored proccudures
---how to create:
Create Procedure spGetEmployeesByGenderAndDepartment 
@ManagerId nvarchar(50),
@DepartmentId int
as
Begin
  Select FIRST_NAME, EMAIL,PHONE_NUMBER from EMPLOYEES Where MANAGER_ID = @ManagerId and DEPARTMENT_ID = @DepartmentId
End

--how to call:
EXECUTE spGetEmployeesByManagerAndDep @DepartmentId=90, @ManagerId = '100'


--stored proccudures with an output value:
--create:
Create Procedure spGetEmployeeCountByGender
@Gender nvarchar(20),
@EmployeeCount int Output
as
Begin
 Select @EmployeeCount = COUNT(Id) 
 from tblEmployee 
 where Gender = @Gender
End
--call
Declare @EmployeeTotal int
Execute spGetEmployeeCountByGender 'Female', @EmployeeTotal out

--stored proccudure with a returned value (only use return with integer values):
Create Procedure spGetTotalCountOfEmployees2
as
Begin
 return (Select COUNT(ID) from Employees)
End

--call
Declare @TotalEmployees int
Execute @TotalEmployees = spGetTotalCountOfEmployees2
Select @TotalEmployees

--functions:
-- 1) scalar functions:
--they return a single value of a specfic type i.e varchar, int etc...
CREATE FUNCTION Age(@DOB Date)  
RETURNS INT  
AS  
BEGIN  
 DECLARE @Age INT  
 SET @Age = DATEDIFF(YEAR, @DOB, GETDATE()) - CASE WHEN (MONTH(@DOB) > MONTH(GETDATE())) OR (MONTH(@DOB) = MONTH(GETDATE()) AND DAY(@DOB) > DAY(GETDATE())) THEN 1 ELSE 0 END  
 RETURN @Age  
END
---functions can be used in select statements and conditions
SELECT [EMPLOYEE_ID]
      ,[FIRST_NAME]
      ,[LAST_NAME]
      ,[EMAIL]
      ,[PHONE_NUMBER]
      ,dbo.age([HIRE_DATE]) as 'service years'
  FROM [HR].[dbo].[EMPLOYEES] where dbo.age([HIRE_DATE])>20

-- 2) inline function
--they return a table 
--the below inline function returns all employees who are part of the specfied department id
CREATE FUNCTION fn_EmployeesByDepID(@DepId int)
RETURNS TABLE
AS
RETURN (SELECT [EMPLOYEE_ID]
      ,[FIRST_NAME]
      ,[LAST_NAME]
      ,[EMAIL]
      ,[PHONE_NUMBER]
      ,[HIRE_DATE]
      ,[JOB_ID]
      ,[SALARY]
      ,[MANAGER_ID]
  FROM [EMPLOYEES]
      where [DEPARTMENT_ID] = @DepId)
-- which can then be called like below, and you can also use a join with an other table when fetching from this function, as you are basically dealing with a table.
select * from fn_EmployeesByDepID(90) a inner join JOBS b on a.JOB_ID=b.JOB_ID;
--you can also use an inline function in an update statement
update fn_EmployeesByDepID(90) set Phone_Number='0798632519' where Employee_ID='211'


 
-- 3)Multi-Statement Table Valued Functions
--returns a table instance as specificed in its select statement
-- for differences: https://csharp-video-tutorials.blogspot.com/2012/09/multi-statement-table-valued-functions.html

create function [dbo].[fn_GetEmployees]()
returns @table table (Id int, EmpNAME varchar(40), HireDate Date)
as
begin
insert into @table
SELECT [EMPLOYEE_ID],[FIRST_NAME]+' '+[LAST_NAME],[HIRE_DATE]
FROM [EMPLOYEES]
return
end


--encrypting a function:
--to encrypt a function we add the 'with encryption' keyword below the returns keyword 
ALTER FUNCTION [dbo].[GETID]()
RETURNS INT
with encryption
AS  
BEGIN
DECLARE @maxID int
set @maxID = (select max([EMPLOYEE_ID]) from EMPLOYEES) 
RETURN @maxID + 1
END

--schema binding a function with a table, so the binding stops it from getting dropped
ALTER FUNCTION [dbo].[GETID]()
RETURNS INT
with SchemaBinding
AS  
BEGIN
DECLARE @maxID int
set @maxID = (select max([EMPLOYEE_ID]) from dbo.EMPLOYEES) 
RETURN @maxID + 1
END

--more about functions: https://csharp-video-tutorials.blogspot.com/2012/09/important-concepts-related-to-functions.html



--temporary tables:
--tables that are created to contain data that is not permenat and will be dropped when the session is closed
--In SQL Server, there are 2 types of Temporary tables - Local Temporary tables and Global Temporary tables.
--Local temporary tables are only visible to that session of the SQL Server which has created it, 
--where as Global temporary tables are visible to all the SQL server sessions.

--Local temporary tables are automatically dropped, when the session that created the temporary tables is closed, 
--where as Global temporary tables are destroyed when the last connection that is referencing the global temp table is closed.

--how to create local temp tables
 Create Table #PersonDetails(Id int, Name nvarchar(20))
--how to create global temp tables
 Create Table ##EmployeeDetails(Id int, Name nvarchar(20))
 
-- you can also use them inside stored proccudures as in the below example
Create Procedure spCreateLocalTempTable
as
Begin

select * into #LinkMonsterDetails from MONSTERS where TYPE='Link Monster'

Select * from #LinkMonsterDetails
End




--indexes
-- how to create:

  create index ix_monsters on [MONSTERS] (attack asc)
  create nonclustered index ixemployeesphones on EMPLOYEES (EMPLOYEE_ID DESC, PHONE_NUMBER DESC)

  
--get info on table indexes:
sp_helpindex EMPLOYEES


-- By default, duplicate values are not allowed on key columns, when you have a unique index or constraint.
-- For, example, if I try to insert 10 rows, out of which 5 rows contain duplicates, then all the 10 rows are rejected. 
--However, if I want only the 5 duplicate rows to be rejected and accept the non-duplicate 5 rows, then I can use IGNORE_DUP_KEY option. 
--An example of using IGNORE_DUP_KEY option is shown below.
CREATE UNIQUE INDEX IX_tblEmployee_City
ON tblEmployee(City)
WITH IGNORE_DUP_KEY




--triggers:
--special kind of stored procedure that automatically executes when an event occurs in the database server
CREATE TRIGGER [dbo].[tr_tblEMployee_ForInsert]
ON [dbo].[EMPLOYEES]
FOR INSERT
AS
BEGIN
 Declare @Id int
 Select @Id = EMPLOYEE_ID from inserted
 
 insert into tblEmployeeAudit 
 values('New employee with Id  = ' + Cast(@Id as nvarchar(5)) + ' is added at ' + cast(Getdate() as nvarchar(20)))
END



--Derived table:

Select DEPARTMENT_NAME, TotalEmployees
from 
 (
  Select [DEPARTMENT_NAME], a.[DEPARTMENT_ID], COUNT(*) as TotalEmployees
  from EMPLOYEES a
  join DEPARTMENTS b
  on a.DEPARTMENT_ID = b.DEPARTMENT_ID
  group by [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
 ) 
as EmployeeCount
where TotalEmployees >= 2

--common table expression
With EmployeeCount([DEPARTMENT_NAME], [DEPARTMENT_ID], TotalEmployees)
as
(
  Select [DEPARTMENT_NAME], a.[DEPARTMENT_ID], COUNT(*) as TotalEmployees
  from EMPLOYEES a
  join DEPARTMENTS b
  on a.DEPARTMENT_ID = b.DEPARTMENT_ID
  group by [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
)

Select [DEPARTMENT_NAME], TotalEmployees
from EmployeeCount
where TotalEmployees >= 2

--the the column names on top are optional and therefore you can also write it like this:
With EmployeeCount
as
(
  Select [DEPARTMENT_NAME], a.[DEPARTMENT_ID], COUNT(*) as TotalEmployees
  from EMPLOYEES a
  join DEPARTMENTS b
  on a.DEPARTMENT_ID = b.DEPARTMENT_ID
  group by [DEPARTMENT_NAME], a.[DEPARTMENT_ID]
)

Select [DEPARTMENT_NAME], TotalEmployees
from EmployeeCount
where TotalEmployees >= 2


---- try catch and error handling:
---https://csharp-video-tutorials.blogspot.com/2012/10/error-handling-in-sql-server-2000-part.html
---https://csharp-video-tutorials.blogspot.com/2012/10/error-handling-in-sql-server-2005-and_6.html




--Transactions
--A transaction is a group of commands that change the data stored in a database. A transaction, is treated as a single unit. A transaction ensures that, either all of the --commands succeed, or none of them.
 Begin Try
  Begin Transaction
   Update tblMailingAddress set City = 'LONDON' 
   where AddressId = 1 and EmployeeNumber = 101
   
   Update tblPhysicalAddress set City = 'LONDON' 
   where AddressId = 1 and EmployeeNumber = 101
  Commit Transaction
 End Try
 Begin Catch
  Rollback Transaction
 End Catch 



--importing data from a csv file with sql commands
BULK INSERT dbo.Actors
FROM 'C:\Documents\Skyvia\csv-to-mssql\actor.csv'
WITH
(
        FORMAT='CSV',
        FIRSTROW=2
)
GO


--- cursors:

declare @userFk uniqueidentifier

declare crsr cursor for 
select objectid from AppSetting
open crsr
fetch next from crsr into @userFk

while (@@FETCH_STATUS=0)
begin

fetch next from crsr into @userFk
print @userFk

end
close crsr
deallocate crsr





CREATE TABLE [dbo].[tblEmployee](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[Name] [nvarchar](50) NULL,
	[Gender] [nvarchar](50) NULL,
	[Salary] [nvarchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO 




CREATE PROCEDURE [dbo].[Sp_AddEmployee]
	-- Add the parameters for the stored procedure here
	@Name nvarchar(50),
	@Gender nvarchar(20),
	@Salary int

AS
BEGIN

	INSERT INTO [dbo].[tblEmployee]
           ([Name]
           ,[Gender]
           ,[Salary])
     VALUES
           (@Name
           ,@Gender
           ,@Salary)



END


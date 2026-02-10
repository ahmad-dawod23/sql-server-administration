/* step 1 */


DBCC SHOW_STATISTICS('HumanResources.Department','AK_Department_Name')

/* step 2 */


CREATE TABLE tbl_showstatistics_sampledata 
    ( 
      ID INT IDENTITY(1, 1) , 
      Name VARCHAR(50) CONSTRAINT PK_ID PRIMARY KEY CLUSTERED ( ID ), 
  Age int, 
  address varchar(150), 
  City varchar(50) 
    ) 
 go

CREATE INDEX IX_name ON tbl_showstatistics_sampledata (Name) 
 go

-- Now let's insert some data in to the table and update statistics.  

INSERT  INTO dbo.tbl_showstatistics_sampledata ( Name ,Age, address, City) 
VALUES  ( 'John',25,'Address1', 'City1') 
GO 10000 

-- Update the statistics 

exec sp_updatestats 
go

-- check statistics
DBCC SHOW_STATISTICS('tbl_showstatistics_sampledata','PK_ID') 



/* step 3 */

set nocount on
go
declare @x int 

set @x = 1 

while (@x <=100000) 

begin 

insert into tbl_showstatistics_sampledata (address, City) values ('Address' + convert (varchar, @x % 100), 'City' + convert (varchar, @x % 1000)) 

set @x = @x + 1 

end 

go 

create statistics stats_Address on tbl_showstatistics_sampledata (Address) with fullscan 

create statistics stats_City on tbl_showstatistics_sampledata (City) with fullscan 

go 

dbcc show_statistics (tbl_showstatistics_sampledata, stats_Address) 

dbcc show_statistics (tbl_showstatistics_sampledata, stats_City) 

go 
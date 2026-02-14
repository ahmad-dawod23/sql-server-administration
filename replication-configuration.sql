-----------------------------------------------------------------------
-- REPLICATION CONFIGURATION (SETUP & DISTRIBUTOR)
-- Purpose : Configure distribution, create publications, and set up
--           transactional replication via T-SQL.
-- Safety  : *** THIS SCRIPT CONTAINS DDL — REVIEW BEFORE EXECUTING ***
--           Includes sp_dropdistributor, sp_adddistributor, and
--           publication creation commands that MODIFY server config.
--           Do NOT run blindly — understand each step first.
-- Applies to : On-prem SQL Server
-----------------------------------------------------------------------

/*
IMPORTANT: When connecting to SSMS, use [server\instance] format with the proper server name. 
           Incorrect connection format may result in error: "The Distributor has not been installed correctly. Could not enable database for publishing."

IMPORTANT: Primary keys are required for transactional replication.

IMPORTANT: Initial setup may encounter domain user authentication issues. 
           Recommended workaround: Use SQL Agent process user initially, then switch to domain user after configuration.

NOTE: Domain user errors are typically caused by insufficient service permissions. 
      In properly configured domains with appropriate permissions, domain users work correctly.
      You may need to enable TCP/IP and named pipes protocols.

NOTE: Creating publications via GUI is straightforward. The script below demonstrates programmatic publication creation using T-SQL.
*/
--==============================================================
-- replication - create publication - complete
-- marcelo miorelli
-- 06-Oct-2015
--==============================================================

select @@servername
select @@version
select @@spid
select @@servicename

--==============================================================
-- step 00 -- Configuring the distributor
-- If a distributor already exists and is not functioning properly,
-- review the related jobs and consider removing it using this step.
-- Run this step when you encounter distributor errors during publication creation.
--==============================================================

use master
go
sp_dropdistributor 
-- Could not drop the Distributor 'QG-V-SQL-TS\AIFS_DEVELOPMENT'. This Distributor has associated distribution databases.

EXEC sp_dropdistributor 
     @no_checks = 1
    ,@ignore_distributor = 1
GO

--==============================================================
-- step 01 -- Configuring the distributor
-- Configure the distributor server and admin password for this instance.
-- Create the distributor database.
--==============================================================

use master
exec sp_adddistributor 
 @distributor = N'the_same_server'
,@heartbeat_interval=10
,@password='#J4g4nn4th4_the_password#'

USE master
EXEC sp_adddistributiondb 
    @database = 'dist1', 
    @security_mode = 1;
GO

exec sp_adddistpublisher @publisher = N'the_same_server', 
                         @distribution_db = N'dist1';
GO

--==============================================================
-- Verify distributor configuration before creating publications
--==============================================================

USE master;  
go  

--Is the current server a Distributor?  
--Is the distribution database installed?  
--Are there other Publishers using this Distributor?  
EXEC sp_get_distributor  

--Is the current server a Distributor?  
SELECT is_distributor FROM sys.servers WHERE name='repl_distributor' AND data_source=@@servername;  

--Which databases on the Distributor are distribution databases?  
SELECT name FROM sys.databases WHERE is_distributor = 1  

--What are the Distributor and distribution database properties?  
EXEC sp_helpdistributor;  
EXEC sp_helpdistributiondb;  
EXEC sp_helpdistpublisher;  

--==============================================================
-- Prerequisites: A distributor must be configured before this step.

-- Enable replication on the target database
-- Replace 'the_database_to_publish' with your actual database name
--==============================================================
use master
exec sp_get_distributor


use master
exec sp_replicationdboption @dbname = N'the_database_to_publish', 
                            @optname = N'publish', 
                            @value = N'true'
GO
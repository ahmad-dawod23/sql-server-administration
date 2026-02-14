-----------------------------------------------------------------------
-- SQL AGENT JOBS — TROUBLESHOOTING & MONITORING
-- Purpose : Monitor running jobs, review schedules, investigate
--           failures, and analyze job duration history.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 0. MI CONNECTIVITY TEST VIA SQL AGENT JOB
--    Use this to test outbound connectivity from a Managed Instance.
-----------------------------------------------------------------------
--SQL agent job on the problem MI server, follow the below steps:
 
--1- Create a job 
--2- Create a step with step name 'Test Connection' 
--3- Add the below PowerShell script:

-- tnc login.windows.net  -port 443 | select ComputerName, RemoteAddress, TcpTestSucceeded | Format-List

-- dns resolution test
-- nslookup faultyendpoint.com

--4- Save and close job
--5- Goto jobs area in SQL Agent 
--6- Right-click on the created job and select 'Start Job at Step'
--7- After making sure the job executed successfully
--8- Run the below script and send the results to me:

---- find running sql agent jobs

SELECT
    ja.job_id,
    j.name AS job_name,
    ja.start_execution_date,
    DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) AS elapsed_seconds,
    s.session_id,
    r.command
FROM msdb.dbo.sysjobactivity AS ja
INNER JOIN msdb.dbo.sysjobs AS j
    ON ja.job_id = j.job_id
INNER JOIN msdb.dbo.syssessions AS s
    ON ja.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests AS r
    ON r.session_id = s.session_id
WHERE ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL;
  
  

/*
	Find jobs that contain PowerShell or CmdExec steps
*/

SELECT jobs.name AS job,
       steps.step_id,
       steps.step_name,
       steps.subsystem
FROM msdb.dbo.sysjobsteps AS steps
         INNER JOIN
     msdb.dbo.sysjobs AS jobs
     ON steps.job_id = jobs.job_id
WHERE steps.subsystem IN ('PowerShell', 'CmdExec')
order by 1, 2

/**********************************************************************************************/
-- report of all the SQL Agent jobs and their schedules
SELECT	 [JobName] = [jobs].[name]
		,[Category] = [categories].[name]
		,[Owner] = SUSER_SNAME([jobs].[owner_sid])
		,[Enabled] = CASE [jobs].[enabled] WHEN 1 THEN 'Yes' ELSE 'No' END
		,[Scheduled] = CASE [schedule].[enabled] WHEN 1 THEN 'Yes' ELSE 'No' END
		,[Description] = [jobs].[description]
		,[Occurs] = 
				CASE [schedule].[freq_type]
					WHEN   1 THEN 'Once'
					WHEN   4 THEN 'Daily'
					WHEN   8 THEN 'Weekly'
					WHEN  16 THEN 'Monthly'
					WHEN  32 THEN 'Monthly relative'
					WHEN  64 THEN 'When SQL Server Agent starts'
					WHEN 128 THEN 'Start whenever the CPU(s) become idle' 
					ELSE ''
				END
		,[Occurs_detail] = 
				CASE [schedule].[freq_type]
					WHEN   1 THEN 'O'
					WHEN   4 THEN 'Every ' + CONVERT(VARCHAR, [schedule].[freq_interval]) + ' day(s)'
					WHEN   8 THEN 'Every ' + CONVERT(VARCHAR, [schedule].[freq_recurrence_factor]) + ' weeks(s) on ' + 
						LEFT(
							CASE WHEN [schedule].[freq_interval] &  1 =  1 THEN 'Sunday, '    ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] &  2 =  2 THEN 'Monday, '    ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] &  4 =  4 THEN 'Tuesday, '   ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] &  8 =  8 THEN 'Wednesday, ' ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] & 16 = 16 THEN 'Thursday, '  ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] & 32 = 32 THEN 'Friday, '    ELSE '' END + 
							CASE WHEN [schedule].[freq_interval] & 64 = 64 THEN 'Saturday, '  ELSE '' END , 
							LEN(
								CASE WHEN [schedule].[freq_interval] &  1 =  1 THEN 'Sunday, '    ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] &  2 =  2 THEN 'Monday, '    ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] &  4 =  4 THEN 'Tuesday, '   ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] &  8 =  8 THEN 'Wednesday, ' ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] & 16 = 16 THEN 'Thursday, '  ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] & 32 = 32 THEN 'Friday, '    ELSE '' END + 
								CASE WHEN [schedule].[freq_interval] & 64 = 64 THEN 'Saturday, '  ELSE '' END 
							) - 1
						)
					WHEN  16 THEN 'Day ' + CONVERT(VARCHAR, [schedule].[freq_interval]) + ' of every ' + CONVERT(VARCHAR, [schedule].[freq_recurrence_factor]) + ' month(s)'
					WHEN  32 THEN 'The ' + 
							CASE [schedule].[freq_relative_interval]
								WHEN  1 THEN 'First'
								WHEN  2 THEN 'Second'
								WHEN  4 THEN 'Third'
								WHEN  8 THEN 'Fourth'
								WHEN 16 THEN 'Last' 
							END +
							CASE [schedule].[freq_interval]
								WHEN  1 THEN ' Sunday'
								WHEN  2 THEN ' Monday'
								WHEN  3 THEN ' Tuesday'
								WHEN  4 THEN ' Wednesday'
								WHEN  5 THEN ' Thursday'
								WHEN  6 THEN ' Friday'
								WHEN  7 THEN ' Saturday'
								WHEN  8 THEN ' Day'
								WHEN  9 THEN ' Weekday'
								WHEN 10 THEN ' Weekend Day' 
							END + ' of every ' + CONVERT(VARCHAR, [schedule].[freq_recurrence_factor]) + ' month(s)' 
					ELSE ''
				END
		,[Frequency] = 
				CASE [schedule].[freq_subday_type]
					WHEN 1 THEN 'Occurs once at ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_start_time]), 6), 5, 0, ':'), 3, 0, ':')
					WHEN 2 THEN 'Occurs every ' + 
								CONVERT(VARCHAR, [schedule].[freq_subday_interval]) + ' Seconds(s) between ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_start_time]), 6), 5, 0, ':'), 3, 0, ':') + ' and ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_end_time]), 6), 5, 0, ':'), 3, 0, ':')
					WHEN 4 THEN 'Occurs every ' + 
								CONVERT(VARCHAR, [schedule].[freq_subday_interval]) + ' Minute(s) between ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_start_time]), 6), 5, 0, ':'), 3, 0, ':') + ' and ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_end_time]), 6), 5, 0, ':'), 3, 0, ':')
					WHEN 8 THEN 'Occurs every ' + 
								CONVERT(VARCHAR, [schedule].[freq_subday_interval]) + ' Hour(s) between ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_start_time]), 6), 5, 0, ':'), 3, 0, ':') + ' and ' + 
								STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [schedule].[active_end_time]), 6), 5, 0, ':'), 3, 0, ':')
					ELSE ''
				END
		,[AvgDurationInSec] = CONVERT(DECIMAL(10, 2), [jobhistory].[AvgDuration])
		,[Next_Run_Date] = 
				CASE [jobschedule].[next_run_date]
					WHEN 0 THEN CONVERT(DATETIME, '1900/1/1')
					ELSE CONVERT(DATETIME, CONVERT(CHAR(8), [jobschedule].[next_run_date], 112) + ' ' + 
						 STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), [jobschedule].[next_run_time]), 6), 5, 0, ':'), 3, 0, ':'))
				END
FROM	 [msdb].[dbo].[sysjobs] AS [jobs] WITh(NOLOCK) 
		 LEFT OUTER JOIN [msdb].[dbo].[sysjobschedules] AS [jobschedule] WITh(NOLOCK) 
				 ON [jobs].[job_id] = [jobschedule].[job_id] 
		 LEFT OUTER JOIN [msdb].[dbo].[sysschedules] AS [schedule] WITh(NOLOCK) 
				 ON [jobschedule].[schedule_id] = [schedule].[schedule_id] 
		 INNER JOIN [msdb].[dbo].[syscategories] [categories] WITh(NOLOCK) 
				 ON [jobs].[category_id] = [categories].[category_id] 
		 LEFT OUTER JOIN 
					(	SELECT	 [job_id], [AvgDuration] = (SUM((([run_duration] / 10000 * 3600) + 
																(([run_duration] % 10000) / 100 * 60) + 
																 ([run_duration] % 10000) % 100)) * 1.0) / COUNT([job_id])
						FROM	 [msdb].[dbo].[sysjobhistory] WITh(NOLOCK)
						WHERE	 [step_id] = 0 
						GROUP BY [job_id]
					 ) AS [jobhistory] 
				 ON [jobhistory].[job_id] = [jobs].[job_id]
-- WHERE [jobs].name like '%Maintenance%'
-- ORDER BY 10
GO

/**********************************************************************************************/
-- This queries the sysjobs, sysjobschedules and sysjobhistory table to
-- produce a resultset showing the jobs on a server plus their schedules
-- (if applicable) and the maximum duration of the job.
--
-- The UNION join is to cater for jobs that have been scheduled but not yet
-- run, as this information is stored in the 'active_start...' fields of the
-- sysjobschedules table, whereas if the job has already run the schedule
-- information is stored in the 'next_run...' fields of the sysjobschedules table.
/**********************************************************************************************/
		USE msdb
		Go


		SELECT dbo.sysjobs.Name AS 'Job Name', 
			'Job Enabled' = CASE dbo.sysjobs.Enabled
				WHEN 1 THEN 'Yes'
				WHEN 0 THEN 'No'
			END,
			'Frequency' = CASE dbo.sysschedules.freq_type
				WHEN 1 THEN 'Once'
				WHEN 4 THEN 'Daily'
				WHEN 8 THEN 'Weekly'
				WHEN 16 THEN 'Monthly'
				WHEN 32 THEN 'Monthly relative'
				WHEN 64 THEN 'When SQLServer Agent starts'
			END, 
			'Start Date' = CASE active_start_date
				WHEN 0 THEN null
				ELSE
				substring(convert(varchar(15),active_start_date),1,4) + '/' + 
				substring(convert(varchar(15),active_start_date),5,2) + '/' + 
				substring(convert(varchar(15),active_start_date),7,2)
			END,
			'Start Time' = CASE len(active_start_time)
				WHEN 1 THEN cast('00:00:0' + right(active_start_time,2) as char(8))
				WHEN 2 THEN cast('00:00:' + right(active_start_time,2) as char(8))
				WHEN 3 THEN cast('00:0' 
						+ Left(right(active_start_time,3),1)  
						+':' + right(active_start_time,2) as char (8))
				WHEN 4 THEN cast('00:' 
						+ Left(right(active_start_time,4),2)  
						+':' + right(active_start_time,2) as char (8))
				WHEN 5 THEN cast('0' 
						+ Left(right(active_start_time,5),1) 
						+':' + Left(right(active_start_time,4),2)  
						+':' + right(active_start_time,2) as char (8))
				WHEN 6 THEN cast(Left(right(active_start_time,6),2) 
						+':' + Left(right(active_start_time,4),2)  
						+':' + right(active_start_time,2) as char (8))
			END,
		--	active_start_time as 'Start Time',
			CASE len(run_duration)
				WHEN 1 THEN cast('00:00:0'
						+ cast(run_duration as char) as char (8))
				WHEN 2 THEN cast('00:00:'
						+ cast(run_duration as char) as char (8))
				WHEN 3 THEN cast('00:0' 
						+ Left(right(run_duration,3),1)  
						+':' + right(run_duration,2) as char (8))
				WHEN 4 THEN cast('00:' 
						+ Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
				WHEN 5 THEN cast('0' 
						+ Left(right(run_duration,5),1) 
						+':' + Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
				WHEN 6 THEN cast(Left(right(run_duration,6),2) 
						+':' + Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
			END as 'Max Duration',
			CASE(dbo.sysschedules.freq_subday_interval)
				WHEN 0 THEN 'Once'
				ELSE cast('Every ' 
						+ right(dbo.sysschedules.freq_subday_interval,2) 
						+ ' '
						+     CASE(dbo.sysschedules.freq_subday_type)
									WHEN 1 THEN 'Once'
									WHEN 4 THEN 'Minutes'
									WHEN 8 THEN 'Hours'
								END as char(16))
			END as 'Subday Frequency'
		FROM dbo.sysjobs 
		LEFT OUTER JOIN dbo.sysjobschedules 
		ON dbo.sysjobs.job_id = dbo.sysjobschedules.job_id
		INNER JOIN dbo.sysschedules ON dbo.sysjobschedules.schedule_id = dbo.sysschedules.schedule_id 
		LEFT OUTER JOIN (SELECT job_id, max(run_duration) AS run_duration
				FROM dbo.sysjobhistory
				GROUP BY job_id) Q1
		ON dbo.sysjobs.job_id = Q1.job_id
		WHERE Next_run_time = 0

		UNION

		SELECT dbo.sysjobs.Name AS 'Job Name', 
			'Job Enabled' = CASE dbo.sysjobs.Enabled
				WHEN 1 THEN 'Yes'
				WHEN 0 THEN 'No'
			END,
			'Frequency' = CASE dbo.sysschedules.freq_type
				WHEN 1 THEN 'Once'
				WHEN 4 THEN 'Daily'
				WHEN 8 THEN 'Weekly'
				WHEN 16 THEN 'Monthly'
				WHEN 32 THEN 'Monthly relative'
				WHEN 64 THEN 'When SQLServer Agent starts'
			END, 
			'Start Date' = CASE next_run_date
				WHEN 0 THEN null
				ELSE
				substring(convert(varchar(15),next_run_date),1,4) + '/' + 
				substring(convert(varchar(15),next_run_date),5,2) + '/' + 
				substring(convert(varchar(15),next_run_date),7,2)
			END,
			'Start Time' = CASE len(next_run_time)
				WHEN 1 THEN cast('00:00:0' + right(next_run_time,2) as char(8))
				WHEN 2 THEN cast('00:00:' + right(next_run_time,2) as char(8))
				WHEN 3 THEN cast('00:0' 
						+ Left(right(next_run_time,3),1)  
						+':' + right(next_run_time,2) as char (8))
				WHEN 4 THEN cast('00:' 
						+ Left(right(next_run_time,4),2)  
						+':' + right(next_run_time,2) as char (8))
				WHEN 5 THEN cast('0' + Left(right(next_run_time,5),1) 
						+':' + Left(right(next_run_time,4),2)  
						+':' + right(next_run_time,2) as char (8))
				WHEN 6 THEN cast(Left(right(next_run_time,6),2) 
						+':' + Left(right(next_run_time,4),2)  
						+':' + right(next_run_time,2) as char (8))
			END,
		--	next_run_time as 'Start Time',
			CASE len(run_duration)
				WHEN 1 THEN cast('00:00:0'
						+ cast(run_duration as char) as char (8))
				WHEN 2 THEN cast('00:00:'
						+ cast(run_duration as char) as char (8))
				WHEN 3 THEN cast('00:0' 
						+ Left(right(run_duration,3),1)  
						+':' + right(run_duration,2) as char (8))
				WHEN 4 THEN cast('00:' 
						+ Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
				WHEN 5 THEN cast('0' 
						+ Left(right(run_duration,5),1) 
						+':' + Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
				WHEN 6 THEN cast(Left(right(run_duration,6),2) 
						+':' + Left(right(run_duration,4),2)  
						+':' + right(run_duration,2) as char (8))
			END as 'Max Duration',
			CASE(dbo.sysschedules.freq_subday_interval)
				WHEN 0 THEN 'Once'
				ELSE cast('Every ' 
						+ right(dbo.sysschedules.freq_subday_interval,2) 
						+ ' '
						+     CASE(dbo.sysschedules.freq_subday_type)
									WHEN 1 THEN 'Once'
									WHEN 4 THEN 'Minutes'
									WHEN 8 THEN 'Hours'
								END as char(16))
			END as 'Subday Frequency'
		FROM dbo.sysjobs 
		LEFT OUTER JOIN dbo.sysjobschedules ON dbo.sysjobs.job_id = dbo.sysjobschedules.job_id
		INNER JOIN dbo.sysschedules ON dbo.sysjobschedules.schedule_id = dbo.sysschedules.schedule_id 
		LEFT OUTER JOIN (SELECT job_id, max(run_duration) AS run_duration
				FROM dbo.sysjobhistory
				GROUP BY job_id) Q1
		ON dbo.sysjobs.job_id = Q1.job_id
		WHERE Next_run_time <> 0

		ORDER BY [Start Date],[Start Time]

/**********************************************************************************************/
-- query the results generated by the maintenance tasks:
select * from msdb.dbo.sysmaintplan_log
select * from msdb.dbo.sysmaintplan_logdetail

/**********************************************************************************************/
-- job last executions
SELECT  b.name, 
        a.last_execution_time
FROM    sys.dm_exec_procedure_stats a 
INNER JOIN
        sys.objects b 
        on  a.object_id = b.object_id 
WHERE   DB_NAME(a.database_ID) = 'my_database_name'
ORDER BY
        a.last_execution_time DESC

/**********************************************************************************************/
-- show the recent outcome of the jobs 
WITH jobhistory AS 
( SELECT sj.name, 
         (CASE sjh.run_date 
          WHEN 0 THEN NULL 
          ELSE CONVERT(datetime, 
					   STUFF(STUFF(CAST(sjh.run_date AS nchar(8)), 
					               7,0,'-'), 
					         5,0,'-')
					   + N' ' 
					   + STUFF(STUFF(SUBSTRING(CAST(1000000 + sjh.run_time AS nchar(7)), 
					                 2, 6), 
					                 5, 0, ':'), 
					           3, 0, ':'), 
						120) END) AS RunDate,
          sjh.message, 
          sjh.run_status, 
          sjh.run_duration
  FROM msdb.dbo.sysjobhistory AS sjh 
  INNER JOIN msdb.dbo.sysjobs AS sj
  ON sjh.job_id = sj.job_id	
  WHERE sjh.step_id = 0
)
SELECT * 
FROM jobhistory	
WHERE RunDate > DATEADD(d,-1,SYSDATETIME());
GO

/**********************************************************************************************/
-- View failing job steps in order of date descending
SELECT sj.name, sjh.run_date, sjh.run_time, sjh.message, 
       sjh.run_status, sjh.run_duration
FROM msdb.dbo.sysjobhistory AS sjh 
INNER JOIN msdb.dbo.sysjobs AS sj
ON sjh.job_id = sj.job_id	
WHERE sjh.step_id > 0
AND sjh.run_status <> 1
ORDER BY sjh.run_date DESC;
GO

/**********************************************************************************************/
-- Execute job
EXEC msdb.dbo.sp_start_job 'job_name'

/**********************************************************************************************/
-- disable all jobs on the server
declare @sql nvarchar(max);
set @sql = ''
select @sql = @sql + N'exec msdb.dbo.sp_update_job @job_name = ''' + name + N''', @enabled = 0;' 
	from msdb.dbo.sysjobs
where enabled = 1
order by name;
print @sql;
exec (@sql);

-- disable all jobs on the server by GUID
declare @sql nvarchar(max) = '';
select @sql += N'exec msdb.dbo.sp_update_job @job_id = ''' + CONVERT(nvarchar(36),job_id) + N''', @enabled = 0;' 
	from msdb.dbo.sysjobs
where enabled = 1
order by name;
print @sql;
exec (@sql);

/**********************************************************************************************/
-- Details of the current Proxy Account configuration
-- can be obtained through a set of system views:

dbo.sysproxies             -- returns one row per proxy defined in SQL Server Agent
dbo.sysproxylogin          -- Returns which SQL Server logins are associated with
                           -- each SQL Server Agent Proxy Account. Note that no entry
                           -- for members of the sysadmin role is stored or returned
dbo.sysproxyloginsubsystem -- Returns which SQL Server Agent subsystems are defined for 
                           -- each Proxy Account
dbo.syssubsystems          -- Returns information about all available SQL Server Agent 
                           -- proxy subsystems

/**********************************************************************************************/
-- Query the available proxies on the system     
USE msdb;
GO

SELECT sp.name as ProxyName,
       c.name as CredentialName,
       sp.description as ProxyDescription
FROM dbo.sysproxies AS sp
INNER JOIN sys.credentials AS c
ON sp.credential_id = c.credential_id;
GO

/**********************************************************************************************/
-- Query the proxies defined for job step execution
SELECT sj.name as JobName,
       sjs.step_name,
       sjs.subsystem   ,
       COALESCE(sp.name, 'N/A') as ProxyName
FROM dbo.sysjobs AS sj
INNER JOIN dbo.sysjobsteps AS sjs
ON sj.job_id = sjs.job_id
LEFT JOIN dbo.sysproxies AS sp
ON sjs.proxy_id = sp.proxy_id
ORDER BY sj.name, sjs.step_id; 	
GO

/**********************************************************************************************/
-- Find jobs not owned by sa
SELECT
	sj.Name, SUSER_SNAME(sj.owner_sid) as 'Owner', sj.job_id
FROM 
	msdb.dbo.sysjobs sj
WHERE 
	owner_sid <> 0x01 order by 1

/**********************************************************************************************/
-- Job last execution time
SELECT j.[name], 
CAST(STUFF(STUFF(CAST(jh.run_date as varchar),7,0,'-'),5,0,'-') + ' ' + 
STUFF(STUFF(REPLACE(STR(jh.run_time,6,0),' ','0'),5,0,':'),3,0,':') as datetime) AS [LastRun], 
CASE jh.run_status WHEN 0 THEN 'Failed' 
                   WHEN 1 THEN 'Success' 
                   WHEN 2 THEN 'Retry' 
                   WHEN 3 THEN 'Canceled' 
                   WHEN 4 THEN 'In progress' 
                   END AS [Status] 
FROM (SELECT a.job_id,MAX(a.instance_id) As [instance_id] 
FROM msdb.dbo.sysjobhistory a 
WHERE a.step_id = 0 
GROUP BY a.job_id) b 
INNER JOIN msdb.dbo.sysjobhistory jh ON jh.instance_id=b.instance_id 
INNER JOIN msdb.dbo.sysjobs j ON j.job_id = jh.job_id

/**********************************************************************************************/
--		During the installation of SQL Server, a local group is created with a name in the following format:
--		SQLServerSQLAgentUser$<ComputerName>$<InstanceName>
--		This group is granted all the access privileges needed by the SQL Server Agent account.
--		This only includes the bare minimum permissions that the account needs for SQL Server Agent to function.
--
--      SQL Server Agent Roles ---------------------------------------------------------------------------------

--			sysadmin fixed role members can administer SQL Server Agent
--			Fixed database roles in the msdb control access for other users:

--			SQLAgentUserRole     -- Control permission for jobs and schedules that they own

--			SQLAgentReaderRole   -- All permissions of the SQLAgentUserRole plus permission to
--								 -- view the list of all available jobs and job schedules

--			SQLAgentOperatorRole -- Permission to manage local jobs, view properties for operators
--								 -- and proxies, and enumerate available proxies and alerts
/**********************************************************************************************/


-- Get SQL Server Agent jobs and Category information (Query 10) (SQL Server Agent Jobs)

SELECT sj.name AS [Job Name], sj.[description] AS [Job Description], 

sc.name AS [CategoryName], SUSER_SNAME(sj.owner_sid) AS [Job Owner],

sj.date_created AS [Date Created], sj.[enabled] AS [Job Enabled], h.run_status,

CONVERT(DATETIME, RTRIM(h.run_date) + ' ' + STUFF(STUFF(REPLACE(STR(RTRIM(h.run_time),6,0),' ','0'),3,0,':'),6,0,':')) AS [Last Start Date],

RIGHT(STUFF(STUFF(REPLACE(STR(h.run_duration, 7, 0), ' ', '0'), 4, 0, ':'), 7, 0, ':'),8) AS [Last Duration - HHMMSS],

s.[name] AS [Schedule Name], s.[enabled] AS [Schedule Enabled], js.next_run_date, js.next_run_time

FROM msdb.dbo.sysjobs AS sj WITH (NOLOCK)

LEFT OUTER JOIN

    (SELECT job_id, instance_id = MAX(instance_id)

     FROM msdb.dbo.sysjobhistory WITH (NOLOCK)

     GROUP BY job_id) AS l

ON sj.job_id = l.job_id

LEFT OUTER JOIN msdb.dbo.syscategories AS sc WITH (NOLOCK)

ON sj.category_id = sc.category_id

LEFT OUTER JOIN msdb.dbo.sysjobhistory AS h WITH (NOLOCK)

ON h.job_id = l.job_id

AND h.instance_id = l.instance_id

LEFT OUTER JOIN msdb.dbo.sysjobs_view AS jv WITH (NOLOCK)

ON jv.job_id = sj.job_id

LEFT OUTER JOIN msdb.dbo.sysjobschedules AS js WITH (NOLOCK)

ON jv.job_id = js.job_id

LEFT OUTER JOIN msdb.dbo.sysschedules AS s WITH (NOLOCK)

ON s.schedule_id = js.schedule_id

ORDER BY CONVERT(INT, h.run_duration) DESC, [Last Start Date] DESC OPTION (RECOMPILE);

------





--run_status	





-- Get SQL Server Agent Alert Information (Query 11) (SQL Server Agent Alerts)

SELECT name, event_source, message_id, severity, [enabled], has_notification, 

       delay_between_responses, occurrence_count, last_occurrence_date, last_occurrence_time

FROM msdb.dbo.sysalerts WITH (NOLOCK)

ORDER BY name OPTION (RECOMPILE);

------
-- identify the correct job ID first 
-- also note the other columns to confirm the configuration, especially the "command" column  
SELECT
    sjv.job_id, sjv.name AS 'job_name', sjv.enabled, sjv.category_id, sjv.originating_server,
    sjs.subsystem, sjs.step_id, sjs.step_name, sjs.step_uid, sjs.server, sjs.database_name, sjs.retry_attempts, sjs.output_file_name, sjs.command, sjs.additional_parameters
FROM msdb.dbo.sysjobsteps sjs 
INNER JOIN msdb.dbo.sysjobs_view sjv ON sjv.job_id = sjs.job_id  
WHERE subsystem IN ('Distribution','LogReader','Snapshot')  

-- then feed that job ID to the stored procedure:  
exec msdb.dbo.sp_help_jobhistory @job_id = 'D55F576C-91B7-48D4-9F77-0C4F11105AD6', @mode='FULL'   


-- check what agents have been configured  
select * from MSlogreader_agents;
select * from MSsnapshot_agents;
select * from MSdistribution_agents;



-- replication errors
select top 1000 * from MSrepl_errors order by time desc;



-- get the recent output, sorted by start_date of the agent:
select top 1000 * from MSlogreader_history order by start_time desc, time desc;
select top 1000 * from MSsnapshot_history order by start_time desc, time desc;
select top 1000 * from MSdistribution_history order by start_time desc, time desc;

-- get the most recent output, sorted by event datetime:
select top 1000 * from MSlogreader_history order by time desc;
select top 1000 * from MSsnapshot_history order by time desc;
select top 1000 * from MSdistribution_history order by time desc;

-- get the output filtered on agent id:
-- agent id available from job name or from MSxxxx_agents table - see above
select * from Distribution..MSlogreader_history where agent_id = 1 order by start_time desc, time desc;
select * from Distribution..MSsnapshot_history where agent_id = 1 order by start_time desc, time desc;
select * from Distribution..MSdistribution_history where agent_id = 3 order by start_time desc, time desc;

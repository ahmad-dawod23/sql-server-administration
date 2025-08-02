/*****    Analysis Script    ******/

/**** Top 5 Waits analysis  ****/
exec [sqlmonitor].[WaitStatsTop5Categories] @StartTime = null ,@EndTime =null  
go
/**** Top 5 Waits analysis - others  ****/
exec [sqlmonitor].[WaitStatsTopCategoriesOther] @StartTime = null ,@EndTime =null
go
/**** DB Resource utilization analysis  ****/
exec [sqlmonitor].[sp_Check_DBResourceStats] @StartTime = null ,@EndTime =null
go
/**** Print Blocking Tree, if blocking exists  ****/
exec [sqlmonitor].[sp_Print_BlockingTree]
go
/**** Procedure Cache analysis - very useful to understand the nature of workload ****/
exec [sqlmonitor].[sp_CheckForPlanCachePollution]
go
/**** Resource Intensive Queries with execution statistics and execution plan  ****/
select * from [sqlmonitor].[tbl_ResourceIntensiveQuery]
order by logical_reads desc;   ---> high logical reads results in high CPU / DTU consumption
--order by duration desc;   ---> long running queries
--order by granted_query_memory_kb desc   ---> Memory intensive queries

go




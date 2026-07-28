# SQL Server Administration Scripts

This repository contains SQL Server and Azure SQL Managed Instance administration scripts for triage, performance, replication, security, maintenance, and troubleshooting.

It also includes standalone browser utilities for analyzing deadlocks, network traces, execution plans, and structured SQL-related data locally.

## Quick-start decision tree

**"My server is slow"** — follow this path:

```
Start here
  │
  ├─► Run 00-triage.sql (other scripts/)
  │     Quick snapshot: instance info, running requests, blocking, waits, disk
  │
  ├─► Check top waits
  │     └─► performance-wait-stats.sql
  │           │
  │           ├── CXPACKET/SOS_SCHEDULER_YIELD ──► performance-cpu.sql
  │           ├── PAGEIOLATCH_* / WRITELOG ──────► performance-io-latency.sql
  │           ├── LCK_M_* ──────────────────────► performance-blocking.sql
  │           ├── PAGELATCH_* ──────────────────► performance-tempdb.sql
  │           ├── RESOURCE_SEMAPHORE ───────────► performance-buffer-pool-and-memory-analysis.sql
  │           └── Plan cache bloat ─────────────► performance-plan-cache-analysis.sql
  │
  ├─► Investigate specific queries
  │     └─► performance-general.sql (Query Store, deadlocks, general analysis)
  │
  ├─► Check index/statistics health
  │     └─► performance-index-and-statistics-maintenance.sql
  │
  └─► Check storage (Azure MI)
        └─► sqlmi-specific-queries.sql
```

**"I have a security/login issue"** → `logins-and-security.sql`

**"Alerts/job notifications aren't arriving"** → `database-mail.sql`

**"Replication is broken"** → `replication-troubleshooting-queries.sql`

**"Is my backup OK?"** → `backups-and-restores.sql`

**"Is my config correct?"** → `info-and-best-practices-queries.sql`

## Repository contents

### Root folder

| Script | Purpose | Safety |
|--------|---------|--------|
| advanced-administration-and-recovery.sql | Error logs, instance configuration, service startup failure triage, emergency recovery | **High-risk procedures** |
| ag-dag-link-monitoring-scripts.sql | AG/DAG/Link health, seeding, failover events | Read-only |
| backups-and-restores.sql | Backup/restore progress, history, missing backups | Read-only |
| dangerous-admin-utilities.sql | xp_cmdshell, bulk DROP generators, database offline/detach | **Destructive — all blocks commented out** |
| database-integrity-checks.sql | DBCC CHECKDB/CHECKTABLE/CHECKALLOC, suspect pages, page verification, VLF counts, corruption response | Read-only diagnostics; DBCC + repair templates commented out |
| database-mail.sql | Database Mail triage (failures + error text), queue state, prerequisites, permissions, Agent mail profile, configuration | Read-only diagnostics; remediation, test send + purge/retention commented out |
| disk-space-and-file-management.sql | Volume free space, file sizes, autogrowth, VLFs | Read-only |
| extended-events.sql | XE session templates for monitoring | **Contains DDL** |
| info-and-best-practices-queries.sql | Server, service, hardware, CPU, network, database, and configuration information | Read-only unless noted |
| logins-and-security.sql | Login troubleshooting, permissions audit, orphaned users | Read-only |
| performance-blocking.sql | Head blocker detection, blocking chains, wait stats | Read-only |
| performance-buffer-pool-and-memory-analysis.sql | Buffer pool by DB/object, memory clerks, PLE, grants | Read-only |
| performance-cpu.sql | Top CPU queries (active + Query Store), CPU timeline | Read-only |
| performance-general.sql | Deadlock analysis, Query Store investigation, general performance | Read-only |
| performance-index-and-statistics-maintenance.sql | Fragmentation, rebuild/reorganize, stale stats | **Maintenance window** |
| performance-io-latency.sql | Read/write latency per file, pending I/O | Read-only |
| performance-plan-cache-analysis.sql | Plan cache composition, single-use bloat | Read-only |
| performance-tempdb.sql | TempDB session space, file config, contention | Read-only |
| performance-wait-stats.sql | Top waits (filtered), signal ratio, latch stats | Read-only |
| replication-configuration.sql | Distributor setup, publication creation | **Contains DDL** |
| replication-topology.sql | Automated topology discovery | Read-only |
| replication-troubleshooting-queries.sql | Agent history, tracer tokens, latency | Read-only |
| sql-agent-jobs-troubleshooting.sql | Running jobs, schedules, history, failures | Read-only |
| sqlmi-specific-queries.sql | Azure MI IOPS/throughput, storage limits, MI-specific diagnostics | Read-only |
| tde-and-encryption-status.sql | TDE status, certificates, Always Encrypted | Read-only |

### `other scripts/`

| File | Purpose |
|------|---------|
| 00-triage.sql | **Start here for incidents:** first-response instance, workload, blocking, waits, and storage snapshot |
| ArcadeStoreSchema.sql | Sample arcade database schema and seed data for testing or demonstrations |
| blocking-and-deadlock-simulations.sql | Reproducible blocking and deadlock scenarios for lab environments |
| PerfMonitor-tables-sql-agent-scripts.sql | Performance-capture tables and SQL Agent collection scripts |
| powershell scripts.ps1 | PowerShell administration and diagnostic command collection |
| sp_WhoIsActive.sql | Adam Machanic's community session and activity diagnostic procedure |
| SQL Managed Instance Diagnostic Information Queries.sql | Broad Azure SQL Managed Instance diagnostic query collection |
| stored-procedure-performance-checking.sql | Stored procedure execution and performance investigation queries |
| T-SQL commands.sql | General T-SQL administration command reference |

### `SQL_UTILITIES/`

#### Browser utilities

These single-file tools run locally in a browser; review each page's instructions and supported input before use.

| Utility | Purpose |
|---------|---------|
| sql_deadlock_analyzer.html | Parses SQL Server deadlock XML and presents processes, resources, and victim details |
| sql_mi_network_trace_analyzer_v4.html | Analyzes PCAP/PCAPNG network traces for SQL Server, HADR/MI Link, and Azure SQL MI redirect traffic |
| sql_server_execution_plan_visualizer.html | Visualizes SQL Server XML execution plans |
| sql_xml_json_prettifier.html | Formats and prettifies XML, JSON, and SQL text |

#### Windows utilities

| Utility | Purpose |
|---------|---------|
| IISCrypto.exe | Windows Schannel protocol, cipher, hash, and key-exchange configuration utility |
| SQLCheck.exe | SQL Server connectivity and configuration diagnostic utility |
| SQLNA.exe | Command-line SQL Server network analysis utility |
| SQLNAUI.exe | Graphical SQL Server network analysis utility |
| SSPIClient.exe | SSPI and Windows authentication connectivity diagnostic utility |

## Usage notes

- **Review each script and execute only the required section** — some files mix read-only diagnostics with configuration changes, DDL, or maintenance operations.
- Scripts marked **Contains DDL** create or modify server-level objects. Read the safety header.
- Scripts marked **Maintenance window** perform ALTER INDEX / UPDATE STATISTICS operations.
- Some scripts require elevated permissions and access to system views/DMVs.
- Replace sample database names, paths, thresholds, credentials, and server-specific values before running a script.
- Use simulation and sample-schema scripts only in disposable development or lab databases.

SQL Server Administration Scripts

This repository contains SQL Server and Azure SQL Managed Instance administration scripts for triage, performance, replication, security, maintenance, and troubleshooting.

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
  │     └─► performance-checking-queries.sql (Query Store, deadlocks)
  │
  ├─► Check index/statistics health
  │     └─► performance-index-and-statistics-maintenance.sql
  │
  └─► Check storage (Azure MI)
        └─► performance-iops-and-storage-measuring-script.sql
```

**"I have a security/login issue"** → `logins.sql`

**"Replication is broken"** → `replication-troubleshooting-queries.sql`

**"Is my backup OK?"** → `backups.sql`

**"Is my config correct?"** → `configuration-best-practice-audit.sql`

## Repository contents

### Root folder

| Script | Purpose | Safety |
|--------|---------|--------|
| ag-dag-link-monitoring-scripts.sql | AG/DAG/Link health, seeding, failover events | Read-only |
| backups.sql | Backup/restore progress, history, missing backups | Read-only |
| configuration-best-practice-audit.sql | Instance config audit vs. best practices | Read-only |
| database-integrity-checks.sql | DBCC CHECKDB/CHECKTABLE/CHECKALLOC, suspect pages | Read-only (CPU-intensive) |
| database-mail.sql | Database Mail queue, logs, profiles, diagnostics | Read-only |
| disk-space-and-file-management.sql | Volume free space, file sizes, autogrowth, VLFs | Read-only |
| extended-events.sql | XE session templates for monitoring | **Contains DDL** |
| logins.sql | Login troubleshooting, permissions audit, orphaned users | Read-only |
| performance-blocking.sql | Head blocker detection, blocking chains, wait stats | Read-only |
| performance-buffer-pool-and-memory-analysis.sql | Buffer pool by DB/object, memory clerks, PLE, grants | Read-only |
| performance-checking-queries.sql | Deadlock analysis, Query Store investigation | Read-only |
| performance-cpu.sql | Top CPU queries (active + Query Store), CPU timeline | Read-only |
| performance-index-and-statistics-maintenance.sql | Fragmentation, rebuild/reorganize, stale stats | **Maintenance window** |
| performance-io-latency.sql | Read/write latency per file, pending I/O | Read-only |
| performance-iops-and-storage-measuring-script.sql | Azure MI IOPS/throughput vs. storage limits | Read-only |
| performance-plan-cache-analysis.sql | Plan cache composition, single-use bloat | Read-only |
| performance-tempdb.sql | TempDB session space, file config, contention | Read-only |
| performance-wait-stats.sql | Top waits (filtered), signal ratio, latch stats | Read-only |
| replication-configuration.sql | Distributor setup, publication creation | **Contains DDL** |
| replication-topology.sql | Automated topology discovery | Read-only |
| replication-troubleshooting-queries.sql | Agent history, tracer tokens, latency | Read-only |
| sql-agent-jobs-troubleshooting.sql | Running jobs, schedules, history, failures | Read-only |
| tde-and-encryption-status.sql | TDE status, certificates, Always Encrypted | Read-only |

### other scripts/

- 00-triage.sql — **Start here for incidents** (first-response triage)
- Administration commands V2.0.sql
- gemini administration tests.sql
- PerfMonitor-tables-sql-agent-scripts.sql
- PerfMonitor-tables-views.sql
- PMC-SQLPerfMonitor-Capture and Analysis Script.sql
- powershell scripts.ps1
- sp_WhoIsActive.sql
- SQL Managed Instance Diagnostic Information Queries.sql
- T-SQL commands.sql

### SQL_UTILITIES/

- SQLCheck.exe
- SQLNA.exe
- SQLNAUI.exe
- SSPIClient.exe

## Usage notes

- **Review each script before execution** — some contain DDL or maintenance operations.
- Scripts marked **Contains DDL** create or modify server-level objects. Read the safety header.
- Scripts marked **Maintenance window** perform ALTER INDEX / UPDATE STATISTICS operations.
- All diagnostic scripts use `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` for consistency.
- Some scripts require elevated permissions and access to system views/DMVs.

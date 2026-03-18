# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS Lambda tooling for cross-VPC EFS access using Route 53 Private Hosted Zones (PHZ). Two Lambda components auto-manage PHZ A records so EFS DNS names resolve correctly in consumer VPCs that don't have their own mount targets.

**Language:** Chinese (Simplified) for all user-facing output, docs, and log messages. Python code uses English identifiers.

## Commands

```bash
# Run all tests
uv run --with pytest --no-project -- python -m pytest tests/ -v

# Note: "tests/" here means both audit/tests/ and sync/tests/ via pyproject.toml testpaths.
# From project root, this works because pyproject.toml configures both paths.

# Run a single test file
uv run --with pytest --no-project -- python -m pytest audit/tests/test_checker.py -v

# Run a single test
uv run --with pytest --no-project -- python -m pytest sync/tests/test_handler.py::TestSyncHandler::test_manual_invocation -v

# Deploy (all components)
./deploy.sh --stack-name efs-phz-tools --s3-bucket <BUCKET> \
  --phz-ids "Z001" --efs-vpc-ids "vpc-aaa" --alert-emails "ops@example.com"

# Deploy single component
./deploy.sh ... --components audit   # or sync
```

**Important:** `pip install pytest` fails due to PEP 668. Always use `uv run`.

## Architecture

### Two Lambda Components, One Shared Library

```
                    ┌─────────────────────────────┐
                    │  shared/python/efs_phz_audit │  ← Lambda Layer (shared by both)
                    │  scanner → checker           │     audit path
                    │  scanner → record_manager    │     sync path
                    │  reporter, config            │
                    └──────────┬──────────────────┘
                               │
               ┌───────────────┼───────────────┐
               │                               │
    ┌──────────▼──────────┐        ┌───────────▼──────────┐
    │  audit/             │        │  sync/               │
    │  READ-ONLY          │        │  READ-WRITE          │
    │  EventBridge sched  │        │  CloudTrail→EB→SQS   │
    │  → scan → check     │        │  → scan → reconcile  │
    │  → report + alert   │        │  → UPSERT/DELETE     │
    └─────────────────────┘        └──────────────────────┘
```

- **Audit** (read-only): Scheduled scan that compares expected vs actual PHZ records, publishes CloudWatch metrics (`EFS/PHZAudit`/`IssueCount`), sends SNS email only when issues found.
- **Sync** (read-write): Triggered by CloudTrail EFS events (`CreateMountTarget`, `DeleteMountTarget`, `DeleteFileSystem`) via EventBridge → SQS. Performs full reconciliation: UPSERT missing/wrong records, DELETE stale ones.

### Shared Library Modules (`shared/python/efs_phz_audit/`)

| Module                | Role                                                            | Used by |
| --------------------- | --------------------------------------------------------------- | ------- |
| `scanner.py`        | Scans EFS mount targets in VPCs, builds `ExpectedRecord` list | Both    |
| `checker.py`        | Compares expected vs actual, returns `AuditIssue` list        | Audit   |
| `record_manager.py` | Fetches EFS A records, reconciles with UPSERT/DELETE            | Sync    |
| `reporter.py`       | Builds report dict, publishes CloudWatch metric, sends SNS      | Audit   |
| `config.py`         | `AuditConfig` / `SyncConfig` dataclasses from env vars      | Both    |

### Key Data Types

- `MountTargetInfo` (scanner) — frozen dataclass representing one EFS mount target
- `ExpectedRecord` (scanner) — an A record that *should* exist (`name`, `ip`, `efs_id`, `record_type`)
- `ActualRecord` (checker) — an A record that *does* exist in PHZ (audit path)
- `PhzRecordDetail` (record_manager) — an A record with TTL (sync path)
- `AuditIssue` (checker) — issue with severity/type/detail

### A Record Strategy (critical business logic)

This logic is duplicated in `scanner.build_expected_records()` and `scripts/phz-auto-records.sh`:

- **Single MT EFS**: creates generic (`fs-xxx.efs.region.amazonaws.com`) + per-AZ record
- **Multi MT EFS**: creates per-AZ records only (no generic — avoids cross-AZ traffic costs)
- **Unavailable MT**: skipped entirely

### Infrastructure (template.yaml)

Native CloudFormation (not SAM). Conditional deployment via `DeployAudit`/`DeploySync` parameters. Both Lambdas use Python 3.12 on arm64, share a single Lambda Layer. Sync uses SQS with DLQ (6 retries, 14-day retention).

## Test Conventions

- Tests use pytest fixtures from `conftest.py` in each test directory
- AWS calls are mocked — tests don't hit real AWS
- `pyproject.toml` configures `testpaths = ["audit/tests", "sync/tests"]` and `pythonpath = ["shared/python", "sync"]`
- The sync pythonpath entry allows `from sync_handler.handler import ...` in tests

## Shell Script Conventions

- `set -euo pipefail`, idempotent (check-before-create, UPSERT)
- Output markers: `✓`/`✗` pass/fail, `ⓘ` info, `⚠️` warnings
- Must work with macOS bash 3.2: no `declare -A`, no `((var++))` with `set -e`, always `${var}` near CJK characters
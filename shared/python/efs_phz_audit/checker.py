"""Compare expected records against actual PHZ records and find issues."""

from dataclasses import dataclass
import boto3
import logging

from .scanner import ExpectedRecord

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ActualRecord:
    """An A record that exists in the PHZ."""
    name: str  # FQDN with trailing dot removed
    ip: str


@dataclass(frozen=True)
class AuditIssue:
    severity: str  # HIGH, MEDIUM, WARNING
    issue_type: str  # missing, ip_mismatch, stale, mt_unavailable
    phz_id: str
    detail: str


def fetch_phz_a_records(phz_id: str) -> list[ActualRecord]:
    """Fetch all A records from a PHZ."""
    r53 = boto3.client("route53")
    records: list[ActualRecord] = []

    paginator = r53.get_paginator("list_resource_record_sets")
    for page in paginator.paginate(HostedZoneId=phz_id):
        for rrs in page["ResourceRecordSets"]:
            if rrs["Type"] != "A":
                continue
            name = rrs["Name"].rstrip(".")
            for rr in rrs.get("ResourceRecords", []):
                records.append(ActualRecord(name=name, ip=rr["Value"]))

    logger.info("PHZ %s has %d A records", phz_id, len(records))
    return records


def check_phz(
    phz_id: str,
    expected: list[ExpectedRecord],
    actual: list[ActualRecord],
) -> list[AuditIssue]:
    """Compare expected vs actual records for a single PHZ.

    Returns a list of issues found.
    """
    issues: list[AuditIssue] = []

    # Build lookup maps
    actual_map: dict[str, str] = {r.name: r.ip for r in actual}
    expected_map: dict[str, ExpectedRecord] = {r.name: r for r in expected}

    # 1. Check for missing records
    for name, exp in expected_map.items():
        if name not in actual_map:
            issues.append(AuditIssue(
                severity="HIGH",
                issue_type="missing",
                phz_id=phz_id,
                detail=f"缺失记录: {name} → 期望 {exp.ip} (EFS: {exp.efs_id}, {exp.record_type})",
            ))

    # 2. Check for IP mismatches
    for name, exp in expected_map.items():
        if name in actual_map and actual_map[name] != exp.ip:
            issues.append(AuditIssue(
                severity="HIGH",
                issue_type="ip_mismatch",
                phz_id=phz_id,
                detail=f"IP 不匹配: {name} → PHZ 中为 {actual_map[name]}, 实际 MT IP 为 {exp.ip} (EFS: {exp.efs_id})",
            ))

    # 3. Check for stale records (in PHZ but no matching expected record)
    # Only check records that look like EFS records (contain ".efs." in domain)
    for name, ip in actual_map.items():
        if ".efs." in name and name not in expected_map:
            issues.append(AuditIssue(
                severity="MEDIUM",
                issue_type="stale",
                phz_id=phz_id,
                detail=f"过期记录: {name} → {ip} (PHZ 中存在但无对应 EFS Mount Target)",
            ))

    return issues


def build_mt_warnings(mount_targets) -> list[AuditIssue]:
    """Check for mount targets in non-available state."""
    warnings: list[AuditIssue] = []
    for mt in mount_targets:
        if mt.state != "available":
            warnings.append(AuditIssue(
                severity="WARNING",
                issue_type="mt_unavailable",
                phz_id="N/A",
                detail=f"MT 状态异常: {mt.mount_target_id} ({mt.efs_id} / {mt.az}) 状态为 {mt.state}",
            ))
    return warnings

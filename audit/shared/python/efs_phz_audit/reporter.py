"""Format audit report and send notifications."""

import json
import logging
from datetime import datetime, timezone

import boto3

from .checker import AuditIssue

logger = logging.getLogger(__name__)


def build_report(
    phz_ids: list[str],
    efs_vpc_ids: list[str],
    total_efs: int,
    total_expected: int,
    issues: list[AuditIssue],
) -> dict:
    """Build a structured audit report."""
    issue_counts = {
        "missing": sum(1 for i in issues if i.issue_type == "missing"),
        "ip_mismatch": sum(1 for i in issues if i.issue_type == "ip_mismatch"),
        "stale": sum(1 for i in issues if i.issue_type == "stale"),
        "mt_unavailable": sum(1 for i in issues if i.issue_type == "mt_unavailable"),
    }

    return {
        "audit_time": datetime.now(timezone.utc).isoformat(),
        "audit_result": "ISSUES_FOUND" if issues else "ALL_GOOD",
        "config": {
            "phz_ids": phz_ids,
            "efs_vpc_ids": efs_vpc_ids,
        },
        "summary": {
            "total_efs": total_efs,
            "total_expected_records": total_expected,
            "total_issues": len(issues),
            **issue_counts,
        },
        "issues": [
            {
                "severity": i.severity,
                "type": i.issue_type,
                "phz_id": i.phz_id,
                "detail": i.detail,
            }
            for i in issues
        ],
    }


def publish_cloudwatch_metric(region: str, issue_count: int):
    """Publish audit issue count as a CloudWatch custom metric."""
    cw = boto3.client("cloudwatch", region_name=region)
    cw.put_metric_data(
        Namespace="EFS/PHZAudit",
        MetricData=[
            {
                "MetricName": "IssueCount",
                "Value": issue_count,
                "Unit": "Count",
            }
        ],
    )
    logger.info("Published CloudWatch metric: IssueCount=%d", issue_count)


def send_sns_alert(sns_topic_arn: str, region: str, report: dict):
    """Send SNS alert with audit issues (only called when issues exist)."""
    sns = boto3.client("sns", region_name=region)

    issues = report["issues"]
    summary = report["summary"]

    # Build human-readable email body
    lines = [
        "⚠️ EFS PHZ 巡检发现问题",
        "",
        f"巡检时间: {report['audit_time']}",
        f"PHZ IDs: {', '.join(report['config']['phz_ids'])}",
        f"源 VPCs: {', '.join(report['config']['efs_vpc_ids'])}",
        "",
        "━━━ 问题汇总 ━━━",
        f"  缺失记录 (HIGH):   {summary['missing']}",
        f"  IP 不匹配 (HIGH):  {summary['ip_mismatch']}",
        f"  过期记录 (MEDIUM): {summary['stale']}",
        f"  MT 状态异常 (WARNING): {summary['mt_unavailable']}",
        f"  总计: {summary['total_issues']}",
        "",
        "━━━ 问题详情 ━━━",
    ]

    for i in issues:
        lines.append(f"  [{i['severity']}] {i['detail']}")

    lines.extend([
        "",
        "━━━━━━━━━━━━━━━━━",
        "请检查并修复以上问题。可使用 phz-auto-records.sh 脚本自动修复缺失和 IP 不匹配的记录。",
    ])

    subject = f"[EFS PHZ Audit] {summary['total_issues']} issues detected"

    sns.publish(
        TopicArn=sns_topic_arn,
        Subject=subject,
        Message="\n".join(lines),
    )
    logger.info("Sent SNS alert to %s", sns_topic_arn)

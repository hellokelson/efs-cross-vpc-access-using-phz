"""PHZ Audit Lambda handler."""

import json
import logging

from efs_phz_audit.config import AuditConfig
from efs_phz_audit.scanner import scan_efs_in_vpcs, build_expected_records
from efs_phz_audit.checker import fetch_phz_a_records, check_phz, build_mt_warnings
from efs_phz_audit.reporter import build_report, publish_cloudwatch_metric, send_sns_alert

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """Entry point for scheduled and manual invocations.

    Scheduled: EventBridge triggers with empty event.
    Manual: invoke via CLI or console, event is ignored.
    """
    config = AuditConfig.from_env()

    logger.info("Starting PHZ audit: phz_ids=%s, efs_vpc_ids=%s",
                config.phz_ids, config.efs_vpc_ids)

    # Step 1: Scan all EFS mount targets in source VPCs
    mount_targets = scan_efs_in_vpcs(config.region, config.efs_vpc_ids)

    # Step 2: Build expected records
    expected_records = build_expected_records(config.region, mount_targets)

    # Step 3: Check mount target health warnings
    mt_warnings = build_mt_warnings(mount_targets)

    # Count unique EFS
    unique_efs = len({mt.efs_id for mt in mount_targets})

    # Step 4: Check each PHZ
    all_issues = list(mt_warnings)  # MT warnings are global, add once
    for phz_id in config.phz_ids:
        logger.info("Checking PHZ: %s", phz_id)
        actual_records = fetch_phz_a_records(phz_id)
        issues = check_phz(phz_id, expected_records, actual_records)
        all_issues.extend(issues)
        logger.info("PHZ %s: %d issues found", phz_id, len(issues))

    # Step 5: Build report
    report = build_report(
        phz_ids=config.phz_ids,
        efs_vpc_ids=config.efs_vpc_ids,
        total_efs=unique_efs,
        total_expected=len(expected_records),
        issues=all_issues,
    )

    # Step 6: Log structured result (always)
    logger.info("AUDIT_RESULT: %s", json.dumps(report, ensure_ascii=False))

    # Step 7: Publish CloudWatch metric (always)
    publish_cloudwatch_metric(config.region, len(all_issues))

    # Step 8: Send SNS alert (only if issues found)
    if all_issues:
        send_sns_alert(config.sns_topic_arn, config.region, report)
        logger.info("Audit completed with %d issues, alert sent", len(all_issues))
    else:
        logger.info("Audit completed: all records correct, no alert needed")

    return report

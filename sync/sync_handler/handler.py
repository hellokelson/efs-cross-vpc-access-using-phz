"""PHZ Sync Lambda handler — auto-manage PHZ records on EFS/MT changes."""

import json
import logging

from efs_phz_audit.config import SyncConfig
from efs_phz_audit.scanner import scan_efs_in_vpcs, build_expected_records
from efs_phz_audit.record_manager import (
    fetch_phz_efs_records,
    reconcile_phz_records,
    ReconcileResult,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# CloudTrail event names that trigger reconciliation
TRIGGER_EVENTS = {"CreateMountTarget", "DeleteMountTarget", "DeleteFileSystem"}


def _parse_trigger_events(event: dict) -> list[dict]:
    """Extract CloudTrail event details from SQS records.

    Each SQS record body contains an EventBridge event wrapping a CloudTrail event.
    Returns a list of parsed trigger info dicts.
    """
    triggers = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            detail = body.get("detail", {})
            event_name = detail.get("eventName", "")
            if event_name not in TRIGGER_EVENTS:
                logger.warning("Ignoring unexpected event: %s", event_name)
                continue

            trigger = {
                "event_name": event_name,
                "event_time": detail.get("eventTime", ""),
                "request_parameters": detail.get("requestParameters", {}),
                "response_elements": detail.get("responseElements", {}),
            }

            # Extract identifiers for logging
            if event_name == "CreateMountTarget":
                resp = trigger["response_elements"] or {}
                trigger["efs_id"] = resp.get("fileSystemId", "unknown")
                trigger["vpc_id"] = resp.get("vpcId", "unknown")
            elif event_name == "DeleteMountTarget":
                trigger["mount_target_id"] = trigger["request_parameters"].get(
                    "mountTargetId", "unknown"
                )
            elif event_name == "DeleteFileSystem":
                trigger["efs_id"] = trigger["request_parameters"].get(
                    "fileSystemId", "unknown"
                )

            triggers.append(trigger)
        except (json.JSONDecodeError, KeyError) as e:
            logger.error("Failed to parse SQS record: %s", e)
            continue

    return triggers


def lambda_handler(event, context):
    """Entry point for SQS-triggered and manual invocations.

    SQS-triggered: EventBridge → SQS → this Lambda (CloudTrail events).
    Manual: invoke via CLI for on-demand reconciliation.
    """
    config = SyncConfig.from_env()

    # Parse trigger events (SQS) or treat as manual invocation
    triggers = _parse_trigger_events(event) if "Records" in event else []
    is_manual = len(triggers) == 0

    if is_manual:
        logger.info("Manual invocation: running full reconciliation")
    else:
        for t in triggers:
            logger.info("Trigger: %s (efs=%s)", t["event_name"], t.get("efs_id", t.get("mount_target_id", "N/A")))

    # Full reconciliation: scan all EFS → build expected → diff → apply
    logger.info("Scanning EFS in VPCs: %s", config.efs_vpc_ids)
    mount_targets = scan_efs_in_vpcs(config.region, config.efs_vpc_ids)
    expected_records = build_expected_records(config.region, mount_targets)

    logger.info("Found %d mount targets, %d expected records",
                len(mount_targets), len(expected_records))

    # Reconcile each PHZ
    results: dict[str, dict] = {}
    total_upserted = 0
    total_deleted = 0

    for phz_id in config.phz_ids:
        actual = fetch_phz_efs_records(phz_id)
        result = reconcile_phz_records(phz_id, expected_records, actual)
        results[phz_id] = {
            "upserted": result.upserted,
            "deleted": result.deleted,
            "unchanged": result.unchanged,
        }
        total_upserted += len(result.upserted)
        total_deleted += len(result.deleted)

    # Build response
    response = {
        "sync_result": "CHANGES_APPLIED" if (total_upserted + total_deleted) > 0 else "NO_CHANGES",
        "trigger": "manual" if is_manual else [t["event_name"] for t in triggers],
        "summary": {
            "total_upserted": total_upserted,
            "total_deleted": total_deleted,
            "phz_count": len(config.phz_ids),
            "efs_count": len({mt.efs_id for mt in mount_targets}),
            "mount_target_count": len(mount_targets),
        },
        "phz_details": results,
    }

    logger.info("SYNC_RESULT: %s", json.dumps(response, ensure_ascii=False))

    # Send SNS notification if changes were made
    if total_upserted + total_deleted > 0 and config.sns_topic_arn:
        _send_change_notification(config, response, triggers)

    return response


def _send_change_notification(config: "SyncConfig", response: dict, triggers: list[dict]):
    """Send SNS notification about record changes."""
    import boto3
    sns = boto3.client("sns", region_name=config.region)

    summary = response["summary"]
    lines = [
        "EFS PHZ Sync: records updated",
        "",
        f"Trigger: {'manual' if not triggers else ', '.join(t['event_name'] for t in triggers)}",
        f"PHZ IDs: {', '.join(config.phz_ids)}",
        "",
        f"Records upserted: {summary['total_upserted']}",
        f"Records deleted:  {summary['total_deleted']}",
    ]

    # Detail per PHZ
    for phz_id, detail in response["phz_details"].items():
        if detail["upserted"] or detail["deleted"]:
            lines.append(f"\n--- PHZ {phz_id} ---")
            for name in detail["upserted"]:
                lines.append(f"  + {name}")
            for name in detail["deleted"]:
                lines.append(f"  - {name}")

    subject = f"[EFS PHZ Sync] {summary['total_upserted']} upserted, {summary['total_deleted']} deleted"

    sns.publish(
        TopicArn=config.sns_topic_arn,
        Subject=subject[:100],
        Message="\n".join(lines),
    )
    logger.info("Sent change notification to SNS")

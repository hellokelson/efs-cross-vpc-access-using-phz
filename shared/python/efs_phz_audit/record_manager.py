"""Manage PHZ A records: reconcile expected state with actual state."""

from dataclasses import dataclass
import boto3
import logging

from .scanner import ExpectedRecord

logger = logging.getLogger(__name__)

DEFAULT_TTL = 300


@dataclass(frozen=True)
class PhzRecordDetail:
    """A record in PHZ with full detail for modification."""
    name: str
    ip: str
    ttl: int


@dataclass(frozen=True)
class ReconcileResult:
    """Summary of changes made during reconciliation."""
    upserted: list[str]   # record names that were created/updated
    deleted: list[str]    # record names that were deleted
    unchanged: int        # count of records already correct


def fetch_phz_efs_records(phz_id: str) -> list[PhzRecordDetail]:
    """Fetch all A records from a PHZ that look like EFS records."""
    r53 = boto3.client("route53")
    records: list[PhzRecordDetail] = []

    paginator = r53.get_paginator("list_resource_record_sets")
    for page in paginator.paginate(HostedZoneId=phz_id):
        for rrs in page["ResourceRecordSets"]:
            if rrs["Type"] != "A":
                continue
            name = rrs["Name"].rstrip(".")
            if ".efs." not in name:
                continue
            ttl = rrs.get("TTL", DEFAULT_TTL)
            for rr in rrs.get("ResourceRecords", []):
                records.append(PhzRecordDetail(name=name, ip=rr["Value"], ttl=ttl))

    logger.info("PHZ %s: fetched %d EFS A records", phz_id, len(records))
    return records


def reconcile_phz_records(
    phz_id: str,
    expected: list[ExpectedRecord],
    actual: list[PhzRecordDetail],
) -> ReconcileResult:
    """Compare expected vs actual records, apply UPSERT and DELETE changes.

    Returns a summary of what was changed.
    """
    expected_map: dict[str, ExpectedRecord] = {r.name: r for r in expected}
    actual_map: dict[str, PhzRecordDetail] = {r.name: r for r in actual}

    changes: list[dict] = []
    upserted: list[str] = []
    deleted: list[str] = []
    unchanged = 0

    # UPSERT: records that are missing or have wrong IP
    for name, exp in expected_map.items():
        act = actual_map.get(name)
        if act is None or act.ip != exp.ip:
            changes.append({
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": name,
                    "Type": "A",
                    "TTL": DEFAULT_TTL,
                    "ResourceRecords": [{"Value": exp.ip}],
                },
            })
            upserted.append(name)
        else:
            unchanged += 1

    # DELETE: stale EFS records (in PHZ but not expected)
    for name, act in actual_map.items():
        if name not in expected_map:
            changes.append({
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": name,
                    "Type": "A",
                    "TTL": act.ttl,
                    "ResourceRecords": [{"Value": act.ip}],
                },
            })
            deleted.append(name)

    if changes:
        r53 = boto3.client("route53")
        # Route53 allows max 1000 changes per batch
        for i in range(0, len(changes), 1000):
            batch = changes[i:i + 1000]
            r53.change_resource_record_sets(
                HostedZoneId=phz_id,
                ChangeBatch={
                    "Comment": "EFS PHZ Sync: auto-reconcile records",
                    "Changes": batch,
                },
            )
        logger.info(
            "PHZ %s: applied %d changes (%d upsert, %d delete)",
            phz_id, len(changes), len(upserted), len(deleted),
        )
    else:
        logger.info("PHZ %s: no changes needed (%d records correct)", phz_id, unchanged)

    return ReconcileResult(upserted=upserted, deleted=deleted, unchanged=unchanged)

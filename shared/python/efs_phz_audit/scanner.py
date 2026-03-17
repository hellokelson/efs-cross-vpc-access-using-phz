"""Scan EFS mount targets in source VPCs and build expected PHZ records."""

from dataclasses import dataclass
import boto3
import logging

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class MountTargetInfo:
    efs_id: str
    efs_name: str
    mount_target_id: str
    az: str
    ip: str
    state: str
    subnet_id: str


@dataclass(frozen=True)
class ExpectedRecord:
    """An A record that should exist in the PHZ."""
    name: str  # FQDN, e.g. "us-east-1a.fs-xxx.efs.us-east-1.amazonaws.com"
    ip: str
    efs_id: str
    record_type: str  # "generic" or "per-az"


def scan_efs_in_vpcs(region: str, vpc_ids: list[str]) -> list[MountTargetInfo]:
    """Scan all EFS mount targets in the specified VPCs."""
    ec2 = boto3.client("ec2", region_name=region)
    efs = boto3.client("efs", region_name=region)

    # Collect all subnet IDs across specified VPCs
    vpc_subnets: dict[str, str] = {}  # subnet_id -> vpc_id
    for vpc_id in vpc_ids:
        paginator = ec2.get_paginator("describe_subnets")
        for page in paginator.paginate(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]):
            for subnet in page["Subnets"]:
                vpc_subnets[subnet["SubnetId"]] = vpc_id

    logger.info("Found %d subnets across %d VPCs", len(vpc_subnets), len(vpc_ids))

    # List all EFS in the region
    all_fs = []
    paginator = efs.get_paginator("describe_file_systems")
    for page in paginator.paginate():
        all_fs.extend(page["FileSystems"])

    logger.info("Found %d EFS in region %s", len(all_fs), region)

    # For each EFS, check if it has mount targets in our VPCs
    results: list[MountTargetInfo] = []
    for fs in all_fs:
        fs_id = fs["FileSystemId"]
        fs_name = fs.get("Name", "(unnamed)")

        mt_list = []
        mt_resp = efs.describe_mount_targets(FileSystemId=fs_id)
        mt_list.extend(mt_resp["MountTargets"])
        while mt_resp.get("NextMarker"):
            mt_resp = efs.describe_mount_targets(FileSystemId=fs_id, Marker=mt_resp["NextMarker"])
            mt_list.extend(mt_resp["MountTargets"])
        for mt in mt_list:
            if mt["SubnetId"] in vpc_subnets:
                results.append(MountTargetInfo(
                    efs_id=fs_id,
                    efs_name=fs_name,
                    mount_target_id=mt["MountTargetId"],
                    az=mt["AvailabilityZoneName"],
                    ip=mt["IpAddress"],
                    state=mt["LifeCycleState"],
                    subnet_id=mt["SubnetId"],
                ))

    logger.info("Found %d mount targets in specified VPCs", len(results))
    return results


def build_expected_records(region: str, mount_targets: list[MountTargetInfo]) -> list[ExpectedRecord]:
    """Build the expected PHZ A records based on mount targets.

    Logic matches phz-auto-records.sh:
    - Single MT EFS: generic + per-AZ record
    - Multi MT EFS: per-AZ records only (no generic)
    """
    # Group MTs by EFS
    efs_mts: dict[str, list[MountTargetInfo]] = {}
    for mt in mount_targets:
        efs_mts.setdefault(mt.efs_id, []).append(mt)

    records: list[ExpectedRecord] = []
    for efs_id, mts in efs_mts.items():
        available_mts = [m for m in mts if m.state == "available"]
        if not available_mts:
            continue

        # Per-AZ records for all scenarios
        for mt in available_mts:
            records.append(ExpectedRecord(
                name=f"{mt.az}.{efs_id}.efs.{region}.amazonaws.com",
                ip=mt.ip,
                efs_id=efs_id,
                record_type="per-az",
            ))

        # Generic record only for single-MT EFS
        if len(available_mts) == 1:
            mt = available_mts[0]
            records.append(ExpectedRecord(
                name=f"{efs_id}.efs.{region}.amazonaws.com",
                ip=mt.ip,
                efs_id=efs_id,
                record_type="generic",
            ))

    logger.info("Built %d expected records for %d EFS", len(records), len(efs_mts))
    return records

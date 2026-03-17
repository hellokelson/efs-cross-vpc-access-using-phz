"""Shared fixtures for sync tests."""

import pytest
from efs_phz_audit.scanner import MountTargetInfo, ExpectedRecord
from efs_phz_audit.record_manager import PhzRecordDetail


@pytest.fixture
def single_mt_expected():
    """Expected records for a single-MT EFS."""
    return [
        ExpectedRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "generic"),
        ExpectedRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "per-az"),
    ]


@pytest.fixture
def dual_mt_expected():
    """Expected records for a dual-MT EFS."""
    return [
        ExpectedRecord("us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.1.20", "fs-bbb", "per-az"),
        ExpectedRecord("us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.2.20", "fs-bbb", "per-az"),
    ]


@pytest.fixture
def matching_actual_single():
    """Actual PHZ records that match single-MT expected."""
    return [
        PhzRecordDetail("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
        PhzRecordDetail("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
    ]


@pytest.fixture
def sqs_event_create_mt():
    """SQS event wrapping a CloudTrail CreateMountTarget event."""
    import json
    return {
        "Records": [
            {
                "body": json.dumps({
                    "detail-type": "AWS API Call via CloudTrail",
                    "source": "aws.elasticfilesystem",
                    "detail": {
                        "eventSource": "elasticfilesystem.amazonaws.com",
                        "eventName": "CreateMountTarget",
                        "eventTime": "2026-03-17T10:00:00Z",
                        "requestParameters": {
                            "fileSystemId": "fs-aaa",
                            "subnetId": "subnet-1a",
                        },
                        "responseElements": {
                            "mountTargetId": "fsmt-111",
                            "fileSystemId": "fs-aaa",
                            "ipAddress": "10.0.1.10",
                            "availabilityZoneName": "us-east-1a",
                            "vpcId": "vpc-source",
                            "lifeCycleState": "creating",
                        },
                    },
                }),
            }
        ],
    }


@pytest.fixture
def sqs_event_delete_mt():
    """SQS event wrapping a CloudTrail DeleteMountTarget event."""
    import json
    return {
        "Records": [
            {
                "body": json.dumps({
                    "detail-type": "AWS API Call via CloudTrail",
                    "source": "aws.elasticfilesystem",
                    "detail": {
                        "eventSource": "elasticfilesystem.amazonaws.com",
                        "eventName": "DeleteMountTarget",
                        "eventTime": "2026-03-17T11:00:00Z",
                        "requestParameters": {
                            "mountTargetId": "fsmt-111",
                        },
                        "responseElements": None,
                    },
                }),
            }
        ],
    }


@pytest.fixture
def sqs_event_delete_efs():
    """SQS event wrapping a CloudTrail DeleteFileSystem event."""
    import json
    return {
        "Records": [
            {
                "body": json.dumps({
                    "detail-type": "AWS API Call via CloudTrail",
                    "source": "aws.elasticfilesystem",
                    "detail": {
                        "eventSource": "elasticfilesystem.amazonaws.com",
                        "eventName": "DeleteFileSystem",
                        "eventTime": "2026-03-17T12:00:00Z",
                        "requestParameters": {
                            "fileSystemId": "fs-aaa",
                        },
                        "responseElements": None,
                    },
                }),
            }
        ],
    }

"""Shared fixtures for tests."""

import pytest
from efs_phz_audit.scanner import MountTargetInfo, ExpectedRecord
from efs_phz_audit.checker import ActualRecord


@pytest.fixture
def sample_mount_targets():
    """3 EFS: 1 single-MT, 1 dual-MT, 1 with unavailable MT."""
    return [
        # EFS-1: single MT (us-east-1a)
        MountTargetInfo("fs-aaa", "EFS-Single", "mt-1a", "us-east-1a", "10.0.1.10", "available", "subnet-1a"),
        # EFS-2: dual MT (us-east-1a + us-east-1b)
        MountTargetInfo("fs-bbb", "EFS-Dual", "mt-2a", "us-east-1a", "10.0.1.20", "available", "subnet-1a"),
        MountTargetInfo("fs-bbb", "EFS-Dual", "mt-2b", "us-east-1b", "10.0.2.20", "available", "subnet-1b"),
        # EFS-3: single MT but creating state
        MountTargetInfo("fs-ccc", "EFS-Creating", "mt-3a", "us-east-1a", "10.0.1.30", "creating", "subnet-1a"),
    ]


@pytest.fixture
def expected_records_for_sample():
    """Expected records for the sample mount targets above."""
    return [
        # EFS-1 (single MT): generic + per-AZ
        ExpectedRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "generic"),
        ExpectedRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "per-az"),
        # EFS-2 (dual MT): per-AZ only
        ExpectedRecord("us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.1.20", "fs-bbb", "per-az"),
        ExpectedRecord("us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.2.20", "fs-bbb", "per-az"),
        # EFS-3: no records (not available)
    ]


@pytest.fixture
def perfect_actual_records():
    """Actual PHZ records that perfectly match expected."""
    return [
        ActualRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
        ActualRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
        ActualRecord("us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.1.20"),
        ActualRecord("us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.2.20"),
    ]

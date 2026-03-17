"""Tests for scanner module."""

from efs_phz_audit.scanner import build_expected_records


class TestBuildExpectedRecords:
    def test_single_mt_creates_generic_and_peraz(self, sample_mount_targets):
        records = build_expected_records("us-east-1", sample_mount_targets)
        names = {r.name for r in records}

        # Single MT: generic + per-AZ
        assert "fs-aaa.efs.us-east-1.amazonaws.com" in names
        assert "us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com" in names

    def test_dual_mt_creates_peraz_only(self, sample_mount_targets):
        records = build_expected_records("us-east-1", sample_mount_targets)
        names = {r.name for r in records}

        # Dual MT: per-AZ only, no generic
        assert "fs-bbb.efs.us-east-1.amazonaws.com" not in names
        assert "us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com" in names
        assert "us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com" in names

    def test_unavailable_mt_excluded(self, sample_mount_targets):
        records = build_expected_records("us-east-1", sample_mount_targets)
        efs_ids = {r.efs_id for r in records}

        # EFS-3 (creating state) should not have any records
        assert "fs-ccc" not in efs_ids

    def test_correct_ips(self, sample_mount_targets):
        records = build_expected_records("us-east-1", sample_mount_targets)
        record_map = {r.name: r.ip for r in records}

        assert record_map["fs-aaa.efs.us-east-1.amazonaws.com"] == "10.0.1.10"
        assert record_map["us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com"] == "10.0.1.20"
        assert record_map["us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com"] == "10.0.2.20"

    def test_total_record_count(self, sample_mount_targets):
        records = build_expected_records("us-east-1", sample_mount_targets)
        # fs-aaa: 2 (generic + per-AZ), fs-bbb: 2 (per-AZ only), fs-ccc: 0
        assert len(records) == 4

    def test_empty_input(self):
        records = build_expected_records("us-east-1", [])
        assert records == []

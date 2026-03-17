"""Tests for record_manager module."""

from efs_phz_audit.scanner import ExpectedRecord
from efs_phz_audit.record_manager import PhzRecordDetail, reconcile_phz_records
from unittest.mock import patch, MagicMock


class TestReconcilePhzRecords:
    def test_no_changes_when_matching(self, single_mt_expected, matching_actual_single):
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            result = reconcile_phz_records("Z-test", single_mt_expected, matching_actual_single)

        assert result.upserted == []
        assert result.deleted == []
        assert result.unchanged == 2
        mock_boto3.client.assert_not_called()

    def test_upsert_missing_records(self, single_mt_expected):
        actual = []  # PHZ is empty
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            result = reconcile_phz_records("Z-test", single_mt_expected, actual)

        assert len(result.upserted) == 2
        assert result.unchanged == 0
        assert result.deleted == []
        mock_r53.change_resource_record_sets.assert_called_once()
        changes = mock_r53.change_resource_record_sets.call_args[1]["ChangeBatch"]["Changes"]
        assert all(c["Action"] == "UPSERT" for c in changes)

    def test_upsert_ip_mismatch(self, single_mt_expected):
        actual = [
            PhzRecordDetail("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.99", 300),  # wrong IP
            PhzRecordDetail("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
        ]
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            result = reconcile_phz_records("Z-test", single_mt_expected, actual)

        assert len(result.upserted) == 1
        assert "fs-aaa.efs.us-east-1.amazonaws.com" in result.upserted
        assert result.unchanged == 1

    def test_delete_stale_records(self):
        expected = []  # no EFS expected
        actual = [
            PhzRecordDetail("us-east-1a.fs-old.efs.us-east-1.amazonaws.com", "10.0.9.9", 300),
        ]
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            result = reconcile_phz_records("Z-test", expected, actual)

        assert len(result.deleted) == 1
        assert "fs-old" in result.deleted[0]
        changes = mock_r53.change_resource_record_sets.call_args[1]["ChangeBatch"]["Changes"]
        assert changes[0]["Action"] == "DELETE"

    def test_strategy_transition_single_to_multi(self):
        """When adding a second MT, generic record should be deleted."""
        # New expected: dual-MT (per-AZ only, no generic)
        expected = [
            ExpectedRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "per-az"),
            ExpectedRecord("us-east-1b.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.2.10", "fs-aaa", "per-az"),
        ]
        # Old actual: single-MT (has generic + per-AZ)
        actual = [
            PhzRecordDetail("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
            PhzRecordDetail("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
        ]
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            result = reconcile_phz_records("Z-test", expected, actual)

        # generic should be deleted, new per-AZ (1b) should be upserted
        assert "fs-aaa.efs.us-east-1.amazonaws.com" in result.deleted
        assert "us-east-1b.fs-aaa.efs.us-east-1.amazonaws.com" in result.upserted
        assert result.unchanged == 1  # per-AZ (1a) unchanged

    def test_strategy_transition_multi_to_single(self):
        """When removing a MT back to single, generic record should be added."""
        # New expected: single-MT (generic + per-AZ)
        expected = [
            ExpectedRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "generic"),
            ExpectedRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "per-az"),
        ]
        # Old actual: dual-MT (per-AZ only)
        actual = [
            PhzRecordDetail("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", 300),
            PhzRecordDetail("us-east-1b.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.2.10", 300),
        ]
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            result = reconcile_phz_records("Z-test", expected, actual)

        # generic should be upserted, old per-AZ (1b) should be deleted
        assert "fs-aaa.efs.us-east-1.amazonaws.com" in result.upserted
        assert "us-east-1b.fs-aaa.efs.us-east-1.amazonaws.com" in result.deleted
        assert result.unchanged == 1  # per-AZ (1a) unchanged

    def test_preserves_actual_ttl_on_delete(self):
        """DELETE should use the actual record's TTL, not default."""
        expected = []
        actual = [
            PhzRecordDetail("us-east-1a.fs-old.efs.us-east-1.amazonaws.com", "10.0.9.9", 600),
        ]
        with patch("efs_phz_audit.record_manager.boto3") as mock_boto3:
            mock_r53 = MagicMock()
            mock_boto3.client.return_value = mock_r53

            reconcile_phz_records("Z-test", expected, actual)

        changes = mock_r53.change_resource_record_sets.call_args[1]["ChangeBatch"]["Changes"]
        assert changes[0]["ResourceRecordSet"]["TTL"] == 600

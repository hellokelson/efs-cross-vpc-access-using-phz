"""Tests for checker module."""

from efs_phz_audit.checker import check_phz, build_mt_warnings, ActualRecord


class TestCheckPhz:
    def test_all_good(self, expected_records_for_sample, perfect_actual_records):
        issues = check_phz("Z-test", expected_records_for_sample, perfect_actual_records)
        assert len(issues) == 0

    def test_missing_record(self, expected_records_for_sample):
        # PHZ missing the generic record for fs-aaa
        actual = [
            ActualRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
            ActualRecord("us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.1.20"),
            ActualRecord("us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.2.20"),
        ]
        issues = check_phz("Z-test", expected_records_for_sample, actual)

        missing = [i for i in issues if i.issue_type == "missing"]
        assert len(missing) == 1
        assert "fs-aaa.efs.us-east-1.amazonaws.com" in missing[0].detail
        assert missing[0].severity == "HIGH"

    def test_ip_mismatch(self, expected_records_for_sample):
        actual = [
            ActualRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
            ActualRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
            ActualRecord("us-east-1a.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.1.99"),  # wrong IP
            ActualRecord("us-east-1b.fs-bbb.efs.us-east-1.amazonaws.com", "10.0.2.20"),
        ]
        issues = check_phz("Z-test", expected_records_for_sample, actual)

        mismatches = [i for i in issues if i.issue_type == "ip_mismatch"]
        assert len(mismatches) == 1
        assert "10.0.1.99" in mismatches[0].detail
        assert "10.0.1.20" in mismatches[0].detail
        assert mismatches[0].severity == "HIGH"

    def test_stale_record(self, expected_records_for_sample, perfect_actual_records):
        # Add an extra record that has no matching expected
        actual_with_stale = perfect_actual_records + [
            ActualRecord("us-east-1a.fs-deleted.efs.us-east-1.amazonaws.com", "10.0.1.99"),
        ]
        issues = check_phz("Z-test", expected_records_for_sample, actual_with_stale)

        stale = [i for i in issues if i.issue_type == "stale"]
        assert len(stale) == 1
        assert "fs-deleted" in stale[0].detail
        assert stale[0].severity == "MEDIUM"

    def test_non_efs_record_not_flagged_as_stale(self, expected_records_for_sample, perfect_actual_records):
        # A record that doesn't contain .efs. should not be flagged
        actual_with_other = perfect_actual_records + [
            ActualRecord("something.other.amazonaws.com", "1.2.3.4"),
        ]
        issues = check_phz("Z-test", expected_records_for_sample, actual_with_other)
        stale = [i for i in issues if i.issue_type == "stale"]
        assert len(stale) == 0

    def test_multiple_issues(self):
        expected = [
            # fs-aaa: generic + per-AZ
            ActualRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10"),
        ]
        # Hack: use ActualRecord as stand-in for ExpectedRecord structure
        from efs_phz_audit.scanner import ExpectedRecord
        exp = [
            ExpectedRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "generic"),
            ExpectedRecord("us-east-1a.fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.10", "fs-aaa", "per-az"),
        ]
        actual = [
            ActualRecord("fs-aaa.efs.us-east-1.amazonaws.com", "10.0.1.99"),  # wrong IP
            # missing per-AZ record
            ActualRecord("us-east-1a.fs-old.efs.us-east-1.amazonaws.com", "10.0.9.9"),  # stale
        ]
        issues = check_phz("Z-test", exp, actual)

        types = {i.issue_type for i in issues}
        assert "ip_mismatch" in types
        assert "missing" in types
        assert "stale" in types

    def test_phz_id_recorded(self, expected_records_for_sample):
        actual = []  # all missing
        issues = check_phz("Z-my-phz", expected_records_for_sample, actual)
        for issue in issues:
            assert issue.phz_id == "Z-my-phz"


class TestBuildMtWarnings:
    def test_unavailable_mt_warned(self, sample_mount_targets):
        warnings = build_mt_warnings(sample_mount_targets)
        assert len(warnings) == 1
        assert warnings[0].issue_type == "mt_unavailable"
        assert "fs-ccc" in warnings[0].detail
        assert "creating" in warnings[0].detail

    def test_all_available_no_warnings(self, sample_mount_targets):
        available_only = [mt for mt in sample_mount_targets if mt.state == "available"]
        warnings = build_mt_warnings(available_only)
        assert len(warnings) == 0

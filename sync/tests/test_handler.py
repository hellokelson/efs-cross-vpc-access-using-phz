"""Tests for sync handler module."""

import json
from sync_handler.handler import _parse_trigger_events


class TestParseTriggerEvents:
    def test_parse_create_mt(self, sqs_event_create_mt):
        triggers = _parse_trigger_events(sqs_event_create_mt)
        assert len(triggers) == 1
        assert triggers[0]["event_name"] == "CreateMountTarget"
        assert triggers[0]["efs_id"] == "fs-aaa"
        assert triggers[0]["vpc_id"] == "vpc-source"

    def test_parse_delete_mt(self, sqs_event_delete_mt):
        triggers = _parse_trigger_events(sqs_event_delete_mt)
        assert len(triggers) == 1
        assert triggers[0]["event_name"] == "DeleteMountTarget"
        assert triggers[0]["mount_target_id"] == "fsmt-111"

    def test_parse_delete_efs(self, sqs_event_delete_efs):
        triggers = _parse_trigger_events(sqs_event_delete_efs)
        assert len(triggers) == 1
        assert triggers[0]["event_name"] == "DeleteFileSystem"
        assert triggers[0]["efs_id"] == "fs-aaa"

    def test_empty_event(self):
        triggers = _parse_trigger_events({})
        assert triggers == []

    def test_ignores_unknown_event(self):
        event = {
            "Records": [
                {
                    "body": json.dumps({
                        "detail": {
                            "eventName": "DescribeFileSystems",
                        }
                    }),
                }
            ],
        }
        triggers = _parse_trigger_events(event)
        assert triggers == []

    def test_handles_malformed_record(self):
        event = {
            "Records": [
                {"body": "not-json"},
            ],
        }
        triggers = _parse_trigger_events(event)
        assert triggers == []

    def test_multiple_records(self, sqs_event_create_mt, sqs_event_delete_mt):
        combined = {
            "Records": (
                sqs_event_create_mt["Records"]
                + sqs_event_delete_mt["Records"]
            ),
        }
        triggers = _parse_trigger_events(combined)
        assert len(triggers) == 2
        assert triggers[0]["event_name"] == "CreateMountTarget"
        assert triggers[1]["event_name"] == "DeleteMountTarget"

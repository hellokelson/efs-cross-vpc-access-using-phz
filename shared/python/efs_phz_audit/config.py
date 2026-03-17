"""Configuration from Lambda environment variables."""

from dataclasses import dataclass
import os


def _parse_csv(value: str) -> list[str]:
    return [v.strip() for v in value.split(",") if v.strip()]


@dataclass(frozen=True)
class AuditConfig:
    region: str
    phz_ids: list[str]
    efs_vpc_ids: list[str]
    sns_topic_arn: str

    @classmethod
    def from_env(cls) -> "AuditConfig":
        return cls(
            region=os.environ["AWS_REGION"],
            phz_ids=_parse_csv(os.environ["PHZ_IDS"]),
            efs_vpc_ids=_parse_csv(os.environ["EFS_VPC_IDS"]),
            sns_topic_arn=os.environ["SNS_TOPIC_ARN"],
        )


@dataclass(frozen=True)
class SyncConfig:
    region: str
    phz_ids: list[str]
    efs_vpc_ids: list[str]
    sns_topic_arn: str  # empty string if not configured

    @classmethod
    def from_env(cls) -> "SyncConfig":
        return cls(
            region=os.environ["AWS_REGION"],
            phz_ids=_parse_csv(os.environ["PHZ_IDS"]),
            efs_vpc_ids=_parse_csv(os.environ["EFS_VPC_IDS"]),
            sns_topic_arn=os.environ.get("SNS_TOPIC_ARN", ""),
        )

"""Configuration from Lambda environment variables."""

from dataclasses import dataclass, field
import os


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
            phz_ids=[v.strip() for v in os.environ["PHZ_IDS"].split(",") if v.strip()],
            efs_vpc_ids=[v.strip() for v in os.environ["EFS_VPC_IDS"].split(",") if v.strip()],
            sns_topic_arn=os.environ["SNS_TOPIC_ARN"],
        )

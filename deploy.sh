#!/bin/bash
set -euo pipefail

# ============================================================
# EFS PHZ Tools 部署脚本
#
# 支持选择性部署 audit（巡检）和 sync（自动同步）组件。
#
# 用法: ./deploy.sh --stack-name <NAME> --s3-bucket <BUCKET> \
#         --phz-ids "Z1,Z2" --efs-vpc-ids "vpc-a,vpc-b" \
#         --alert-emails "a@example.com" \
#         [--components all|audit|sync] \
#         [--schedule "rate(1 day)"] [--region us-east-1]
# ============================================================

STACK_NAME=""
S3_BUCKET=""
PHZ_IDS=""
EFS_VPC_IDS=""
ALERT_EMAILS=""
COMPONENTS="all"
SCHEDULE="rate(1 day)"
REGION="us-east-1"

usage() {
    cat << 'EOF'
用法: ./deploy.sh [参数]

必填参数:
  --stack-name     CloudFormation Stack 名称
  --s3-bucket      Lambda 部署包的 S3 存储桶
  --phz-ids        PHZ Hosted Zone ID（逗号分隔）
  --efs-vpc-ids    EFS 所在 VPC ID（逗号分隔）
  --alert-emails   告警邮箱（逗号分隔）

可选参数:
  --components     部署组件: all | audit | sync（默认: all）
  --schedule       巡检频率（默认: "rate(1 day)"），仅 audit 组件使用
  --region         AWS Region（默认: us-east-1）

示例:
  # 部署全部组件
  ./deploy.sh --stack-name efs-phz --s3-bucket my-bucket \
    --phz-ids "Z001" --efs-vpc-ids "vpc-aaa" --alert-emails "ops@example.com"

  # 仅部署巡检
  ./deploy.sh --stack-name efs-phz --s3-bucket my-bucket \
    --phz-ids "Z001" --efs-vpc-ids "vpc-aaa" --alert-emails "ops@example.com" \
    --components audit

  # 仅部署自动同步
  ./deploy.sh --stack-name efs-phz --s3-bucket my-bucket \
    --phz-ids "Z001" --efs-vpc-ids "vpc-aaa" --alert-emails "ops@example.com" \
    --components sync
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stack-name)    STACK_NAME="$2"; shift 2 ;;
        --s3-bucket)     S3_BUCKET="$2"; shift 2 ;;
        --phz-ids)       PHZ_IDS="$2"; shift 2 ;;
        --efs-vpc-ids)   EFS_VPC_IDS="$2"; shift 2 ;;
        --alert-emails)  ALERT_EMAILS="$2"; shift 2 ;;
        --alert-email)   ALERT_EMAILS="$2"; shift 2 ;;
        --components)    COMPONENTS="$2"; shift 2 ;;
        --schedule)      SCHEDULE="$2"; shift 2 ;;
        --region)        REGION="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "未知参数: $1"; usage ;;
    esac
done

# --- 参数校验 ---
if [ -z "${STACK_NAME}" ] || [ -z "${S3_BUCKET}" ] || [ -z "${PHZ_IDS}" ] || [ -z "${EFS_VPC_IDS}" ] || [ -z "${ALERT_EMAILS}" ]; then
    echo "错误: 必填参数缺失"
    usage
fi

case "${COMPONENTS}" in
    all)   DEPLOY_AUDIT="true";  DEPLOY_SYNC="true"  ;;
    audit) DEPLOY_AUDIT="true";  DEPLOY_SYNC="false" ;;
    sync)  DEPLOY_AUDIT="false"; DEPLOY_SYNC="true"  ;;
    *)     echo "错误: --components 必须为 all, audit 或 sync"; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
S3_PREFIX="efs-phz-tools"
LAYER_KEY="${S3_PREFIX}/layer.zip"
AUDIT_HANDLER_KEY="${S3_PREFIX}/audit-handler.zip"
SYNC_HANDLER_KEY="${S3_PREFIX}/sync-handler.zip"

echo "=========================================="
echo "  EFS PHZ Tools 部署"
echo "=========================================="
echo ""
echo "Stack:      ${STACK_NAME}"
echo "S3 Bucket:  ${S3_BUCKET}"
echo "Components: ${COMPONENTS} (audit=${DEPLOY_AUDIT}, sync=${DEPLOY_SYNC})"
echo "PHZ IDs:    ${PHZ_IDS}"
echo "EFS VPCs:   ${EFS_VPC_IDS}"
echo "Alert:      ${ALERT_EMAILS}"
if [ "${DEPLOY_AUDIT}" = "true" ]; then
    echo "Schedule:   ${SCHEDULE}"
fi
echo "Region:     ${REGION}"
echo ""

# --- 打包 Lambda Layer（共享） ---
echo "打包 Lambda Layer..."
LAYER_DIR=$(mktemp -d)
mkdir -p "${LAYER_DIR}/python"
cp -r "${SCRIPT_DIR}/shared/python/efs_phz_audit" "${LAYER_DIR}/python/"
find "${LAYER_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
(cd "${LAYER_DIR}" && zip -r layer.zip python/ > /dev/null)
aws s3 cp "${LAYER_DIR}/layer.zip" "s3://${S3_BUCKET}/${LAYER_KEY}" --region "${REGION}" > /dev/null
echo "  Layer 已上传: s3://${S3_BUCKET}/${LAYER_KEY}"
rm -rf "${LAYER_DIR}"

# --- 打包 Audit Handler ---
if [ "${DEPLOY_AUDIT}" = "true" ]; then
    echo "打包 Audit Handler..."
    HANDLER_DIR=$(mktemp -d)
    cp "${SCRIPT_DIR}/audit/audit_handler/handler.py" "${HANDLER_DIR}/"
    (cd "${HANDLER_DIR}" && zip -r handler.zip handler.py > /dev/null)
    aws s3 cp "${HANDLER_DIR}/handler.zip" "s3://${S3_BUCKET}/${AUDIT_HANDLER_KEY}" --region "${REGION}" > /dev/null
    echo "  Audit Handler 已上传: s3://${S3_BUCKET}/${AUDIT_HANDLER_KEY}"
    rm -rf "${HANDLER_DIR}"
fi

# --- 打包 Sync Handler ---
if [ "${DEPLOY_SYNC}" = "true" ]; then
    echo "打包 Sync Handler..."
    HANDLER_DIR=$(mktemp -d)
    cp "${SCRIPT_DIR}/sync/sync_handler/handler.py" "${HANDLER_DIR}/"
    (cd "${HANDLER_DIR}" && zip -r handler.zip handler.py > /dev/null)
    aws s3 cp "${HANDLER_DIR}/handler.zip" "s3://${S3_BUCKET}/${SYNC_HANDLER_KEY}" --region "${REGION}" > /dev/null
    echo "  Sync Handler 已上传: s3://${S3_BUCKET}/${SYNC_HANDLER_KEY}"
    rm -rf "${HANDLER_DIR}"
fi

# --- 部署 CloudFormation ---
echo ""
echo "部署 CloudFormation Stack..."
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/template.yaml" \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        DeployAudit="${DEPLOY_AUDIT}" \
        DeploySync="${DEPLOY_SYNC}" \
        PhzIds="${PHZ_IDS}" \
        EfsVpcIds="${EFS_VPC_IDS}" \
        AlertEmails="${ALERT_EMAILS}" \
        ScheduleExpression="${SCHEDULE}" \
        S3Bucket="${S3_BUCKET}" \
        S3KeyLayer="${LAYER_KEY}" \
        S3KeyAuditHandler="${AUDIT_HANDLER_KEY}" \
        S3KeySyncHandler="${SYNC_HANDLER_KEY}"

echo ""
echo "Stack 部署完成"

# --- 订阅 SNS Topic ---
TOPIC_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`AlertTopicArn`].OutputValue' \
    --output text)

echo ""
echo "订阅 SNS Topic..."
IFS=',' read -ra EMAILS <<< "${ALERT_EMAILS}"
for email in "${EMAILS[@]}"; do
    email=$(echo "${email}" | xargs)  # trim spaces
    existing=$(aws sns list-subscriptions-by-topic \
        --topic-arn "${TOPIC_ARN}" \
        --region "${REGION}" \
        --query "Subscriptions[?Endpoint=='${email}' && Protocol=='email'].SubscriptionArn" \
        --output text 2>/dev/null || true)
    if [ -n "${existing}" ] && [ "${existing}" != "None" ] && [ "${existing}" != "PendingConfirmation" ]; then
        echo "  ${email} (已订阅)"
    else
        aws sns subscribe \
            --topic-arn "${TOPIC_ARN}" \
            --protocol email \
            --notification-endpoint "${email}" \
            --region "${REGION}" > /dev/null
        echo "  ${email} (已发送确认邮件，请查收并确认)"
    fi
done

# --- 输出信息 ---
echo ""
echo "=========================================="
echo "  部署完成"
echo "=========================================="

if [ "${DEPLOY_AUDIT}" = "true" ]; then
    AUDIT_FUNC=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`AuditFunctionName`].OutputValue' \
        --output text)
    echo ""
    echo "[Audit] 手动触发巡检:"
    echo "  aws lambda invoke --function-name ${AUDIT_FUNC} --region ${REGION} /tmp/audit.json && cat /tmp/audit.json | python3 -m json.tool"
fi

if [ "${DEPLOY_SYNC}" = "true" ]; then
    SYNC_FUNC=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`SyncFunctionName`].OutputValue' \
        --output text)
    echo ""
    echo "[Sync] 手动触发同步:"
    echo "  aws lambda invoke --function-name ${SYNC_FUNC} --region ${REGION} /tmp/sync.json && cat /tmp/sync.json | python3 -m json.tool"
    echo ""
    echo "[Sync] 查看 DLQ（失败事件）:"
    echo "  aws sqs get-queue-attributes --queue-url \$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} --query 'Stacks[0].Outputs[?OutputKey==\`SyncQueueUrl\`].OutputValue' --output text | sed 's/sync-queue/sync-dlq/') --attribute-names ApproximateNumberOfMessages --region ${REGION}"
fi

echo ""

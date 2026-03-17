#!/bin/bash
set -euo pipefail

# ============================================================
# EFS PHZ Audit 部署脚本
#
# 用法: ./deploy.sh --stack-name <NAME> --s3-bucket <BUCKET> \
#         --phz-ids "Z1,Z2" --efs-vpc-ids "vpc-a,vpc-b" \
#         --alert-emails "a@example.com,b@example.com" \
#         [--schedule "rate(1 day)"] [--region us-east-1]
# ============================================================

STACK_NAME=""
S3_BUCKET=""
PHZ_IDS=""
EFS_VPC_IDS=""
ALERT_EMAILS=""
SCHEDULE="rate(1 day)"
REGION="us-east-1"

usage() {
    echo "用法: $0 --stack-name <NAME> --s3-bucket <BUCKET> --phz-ids <IDS> --efs-vpc-ids <IDS> --alert-emails <EMAILS> [--schedule <EXPR>] [--region <REGION>]"
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
        --schedule)      SCHEDULE="$2"; shift 2 ;;
        --region)        REGION="$2"; shift 2 ;;
        *)               echo "未知参数: $1"; usage ;;
    esac
done

if [ -z "${STACK_NAME}" ] || [ -z "${S3_BUCKET}" ] || [ -z "${PHZ_IDS}" ] || [ -z "${EFS_VPC_IDS}" ] || [ -z "${ALERT_EMAILS}" ]; then
    echo "错误: 必填参数缺失"
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
S3_PREFIX="efs-phz-audit"
LAYER_KEY="${S3_PREFIX}/layer.zip"
HANDLER_KEY="${S3_PREFIX}/handler.zip"

echo "=========================================="
echo "  EFS PHZ Audit 部署"
echo "=========================================="
echo ""
echo "Stack:      ${STACK_NAME}"
echo "S3 Bucket:  ${S3_BUCKET}"
echo "PHZ IDs:    ${PHZ_IDS}"
echo "EFS VPCs:   ${EFS_VPC_IDS}"
echo "Alert:      ${ALERT_EMAILS}"
echo "Schedule:   ${SCHEDULE}"
echo "Region:     ${REGION}"
echo ""

# --- 打包 Lambda Layer ---
echo "打包 Lambda Layer..."
LAYER_DIR=$(mktemp -d)
mkdir -p "${LAYER_DIR}/python"
cp -r "${SCRIPT_DIR}/shared/python/efs_phz_audit" "${LAYER_DIR}/python/"
find "${LAYER_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
(cd "${LAYER_DIR}" && zip -r layer.zip python/ > /dev/null)
aws s3 cp "${LAYER_DIR}/layer.zip" "s3://${S3_BUCKET}/${LAYER_KEY}" --region "${REGION}" > /dev/null
echo "✓ Layer 已上传: s3://${S3_BUCKET}/${LAYER_KEY}"
rm -rf "${LAYER_DIR}"

# --- 打包 Lambda Handler ---
echo "打包 Lambda Handler..."
HANDLER_DIR=$(mktemp -d)
cp "${SCRIPT_DIR}/audit_handler/handler.py" "${HANDLER_DIR}/"
(cd "${HANDLER_DIR}" && zip -r handler.zip handler.py > /dev/null)
aws s3 cp "${HANDLER_DIR}/handler.zip" "s3://${S3_BUCKET}/${HANDLER_KEY}" --region "${REGION}" > /dev/null
echo "✓ Handler 已上传: s3://${S3_BUCKET}/${HANDLER_KEY}"
rm -rf "${HANDLER_DIR}"

# --- 部署 CloudFormation ---
echo ""
echo "部署 CloudFormation Stack..."
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/template.yaml" \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        PhzIds="${PHZ_IDS}" \
        EfsVpcIds="${EFS_VPC_IDS}" \
        AlertEmails="${ALERT_EMAILS}" \
        ScheduleExpression="${SCHEDULE}" \
        S3Bucket="${S3_BUCKET}" \
        S3KeyLayer="${LAYER_KEY}" \
        S3KeyHandler="${HANDLER_KEY}"

echo ""
echo "✓ Stack 部署完成"

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
    # Check if already subscribed
    existing=$(aws sns list-subscriptions-by-topic \
        --topic-arn "${TOPIC_ARN}" \
        --region "${REGION}" \
        --query "Subscriptions[?Endpoint=='${email}' && Protocol=='email'].SubscriptionArn" \
        --output text 2>/dev/null || true)
    if [ -n "${existing}" ] && [ "${existing}" != "None" ] && [ "${existing}" != "PendingConfirmation" ]; then
        echo "✓ ${email} (已订阅)"
    else
        aws sns subscribe \
            --topic-arn "${TOPIC_ARN}" \
            --protocol email \
            --notification-endpoint "${email}" \
            --region "${REGION}" > /dev/null
        echo "✓ ${email} (已发送确认邮件，请查收并确认)"
    fi
done

# --- 输出信息 ---
echo ""
FUNC_NAME=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`AuditFunctionName`].OutputValue' \
    --output text)

echo "✓ 部署完成"
echo ""
echo "手动触发巡检:"
echo "  aws lambda invoke --function-name ${FUNC_NAME} --region ${REGION} /dev/stdout"
echo ""
echo "查看巡检日志:"
echo "  aws logs tail /aws/lambda/${FUNC_NAME} --region ${REGION} --follow"

# EFS PHZ Audit - 巡检工具部署与使用

## 概述

基于 AWS Lambda 的自动化巡检工具，定期检查 PHZ 中的 DNS A 记录是否与 EFS Mount Target 实际状态一致。

### 检测项

| 检测项 | 严重级别 | 说明 |
|--------|---------|------|
| 缺失记录 | **HIGH** | EFS Mount Target 存在且可用，但 PHZ 中无对应 A 记录 |
| IP 不匹配 | **HIGH** | PHZ A 记录的 IP 与 Mount Target 实际 IP 不一致 |
| 过期记录 | **MEDIUM** | PHZ 中有 EFS 域名的 A 记录，但对应的 EFS/MT 已不存在 |
| MT 状态异常 | **WARNING** | Mount Target 状态非 `available` |

### 架构

```
 EventBridge Schedule (定时触发)
        |
        v
 +------------------+
 |  Lambda Function  |  ──→ CloudWatch Metric (IssueCount, 每次都发)
 +------------------+  ──→ SNS Email (仅有问题时发送)
        |
        +--→ EC2/EFS API: 扫描源 VPC 所有 EFS Mount Target
        +--→ Route 53 API: 读取 PHZ 实际 A 记录
        +--→ 对比期望 vs 实际，生成问题列表
```

---

## 部署

### 前提条件

- AWS CLI v2 已配置
- 一个 S3 存储桶用于存放 Lambda 部署包
- bash 终端 + `zip` 命令

### 参数说明

| 参数 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `--stack-name` | 是 | CloudFormation Stack 名称 | `efs-phz-audit` |
| `--s3-bucket` | 是 | Lambda 部署包的 S3 存储桶 | `my-deploy-bucket` |
| `--phz-ids` | 是 | PHZ Hosted Zone ID（逗号分隔） | `"Z0001ABC,Z0002DEF"` |
| `--efs-vpc-ids` | 是 | EFS 所在 VPC ID（逗号分隔） | `"vpc-aaa"` |
| `--alert-emails` | 是 | 告警邮箱（逗号分隔） | `"a@example.com,b@example.com"` |
| `--schedule` | 否 | 巡检频率，默认 `rate(1 day)` | `"cron(0 2 * * ? *)"` |
| `--region` | 否 | AWS Region，默认 `us-east-1` | `us-west-2` |

### 执行部署

```bash
./deploy.sh \
  --stack-name efs-phz-audit \
  --s3-bucket my-deploy-bucket \
  --phz-ids "Z0001XXXXXXXXX" \
  --efs-vpc-ids "vpc-00c603d55c445a3d9" \
  --alert-emails "ops@example.com" \
  --schedule "cron(0 2 * * ? *)" \
  --region us-east-1
```

### 确认邮箱订阅

部署后每个邮箱会收到 **AWS Notification - Subscription Confirmation** 邮件，**必须点击 "Confirm subscription" 链接**，否则无法收到告警。

> 提示：如果使用 QQ 邮箱等国内邮箱，建议复制确认链接到浏览器打开（避免邮箱安全扫描改写 URL）。

---

## 使用

### 自动巡检

部署完成后，Lambda 按设定频率自动执行：
- **无问题**：仅记录日志 + 发布 CloudWatch Metric（IssueCount=0），不发邮件
- **有问题**：记录日志 + 发布 Metric + 发送告警邮件

### 手动触发

```bash
aws lambda invoke \
  --function-name efs-phz-audit-audit \
  --region us-east-1 \
  /tmp/audit-result.json

cat /tmp/audit-result.json | python3 -m json.tool
```

---

## 巡检结果查收

### 方式一：邮件告警

当巡检发现问题时，所有已确认订阅的邮箱会收到告警邮件：

```
Subject: [EFS PHZ Audit] 2 issues detected

EFS PHZ 巡检发现问题

巡检时间: 2026-03-17T02:00:00+00:00
PHZ IDs: Z0001XXXXXXXXX

━━━ 问题汇总 ━━━
  缺失记录 (HIGH):   1
  IP 不匹配 (HIGH):  1
  总计: 2

━━━ 问题详情 ━━━
  [HIGH] 缺失记录: us-east-1b.fs-0abc.efs.us-east-1.amazonaws.com ...
  [HIGH] IP 不匹配: fs-0def.efs.us-east-1.amazonaws.com ...

请检查并修复以上问题。可使用 phz-auto-records.sh 脚本自动修复。
```

**没有问题时不会发邮件**，避免每日无效通知。

### 方式二：CloudWatch 指标监控

Lambda 每次执行都会发布自定义指标，无论有无问题：

- **Namespace**: `EFS/PHZAudit`
- **MetricName**: `IssueCount`

**在 CloudWatch 控制台查看**：

1. 打开 [CloudWatch 控制台](https://console.aws.amazon.com/cloudwatch/)
2. 左侧导航 → **指标** → **所有指标**
3. 搜索 `EFS/PHZAudit` → 选择 `IssueCount`
4. 设置时间范围为近 7 天，查看巡检趋势

**创建 Dashboard（推荐）**：

1. CloudWatch 控制台 → **控制面板** → **创建控制面板**
2. 添加小部件 → **数字** → 选择 `EFS/PHZAudit` / `IssueCount`
3. 可同时添加折线图查看历史趋势

**CloudWatch Alarm**：

部署自动创建了一个 Alarm `{stack-name}-issues-detected`：
- 在 CloudWatch 控制台 → **警报** 中可查看状态
- **ALARM** 状态 = 过去 24 小时发现过问题
- **OK** 状态 = 过去 24 小时全部正常
- 此 Alarm 仅用于控制台可视化，不会重复发送邮件

### 方式三：Lambda 日志

```bash
# 实时查看巡检日志
aws logs tail /aws/lambda/efs-phz-audit-audit \
  --region us-east-1 \
  --follow

# 搜索巡检结果（结构化 JSON）
aws logs filter-log-events \
  --log-group-name /aws/lambda/efs-phz-audit-audit \
  --region us-east-1 \
  --filter-pattern "AUDIT_RESULT" \
  --query 'events[].message' \
  --output text
```

日志中的 `AUDIT_RESULT` 行包含完整的 JSON 结构化结果，可用于进一步分析或对接其他监控系统。

---

## 问题修复

收到告警后，使用 `phz-auto-records.sh` 修复缺失和 IP 不匹配的记录：

```bash
# 自动修复 A 记录
../scripts/phz-auto-records.sh \
  --phz-id Z0001XXXXXXXXX \
  --source-vpc vpc-00c603d55c445a3d9 \
  --region us-east-1

# 修复后手动巡检确认
aws lambda invoke \
  --function-name efs-phz-audit-audit \
  --region us-east-1 \
  /tmp/verify.json
cat /tmp/verify.json | python3 -m json.tool
# 期望: "audit_result": "ALL_GOOD"
```

对于 **过期记录**，需在 Route 53 控制台或通过 CLI 手动删除。

对于 **MT 状态异常**，需在 EFS 控制台确认 Mount Target 状态。

---

## 运维管理

### 添加/移除告警邮箱

```bash
# 添加：重新运行 deploy.sh（已订阅的不会重复）
./deploy.sh --stack-name efs-phz-audit --s3-bucket ... --alert-emails "old@x.com,new@x.com" ...

# 移除：手动取消订阅
TOPIC_ARN=$(aws cloudformation describe-stacks --stack-name efs-phz-audit --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`AlertTopicArn`].OutputValue' --output text)
aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}" --output table
aws sns unsubscribe --subscription-arn <ARN>
```

### 暂停/恢复巡检

```bash
# 暂停
aws events disable-rule --name efs-phz-audit-schedule --region us-east-1
# 恢复
aws events enable-rule --name efs-phz-audit-schedule --region us-east-1
```

### 卸载

```bash
aws cloudformation delete-stack --stack-name efs-phz-audit --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name efs-phz-audit --region us-east-1
# 可选：清理 S3 部署包
aws s3 rm s3://my-deploy-bucket/efs-phz-audit/ --recursive
```

---

## 成本估算

| 资源 | 费用 | 免费额度 |
|------|------|---------|
| Lambda | ~$0.00/月 | 每月 100 万次请求 + 40 万 GB-秒 |
| EventBridge | ~$0.00/月 | 定时规则触发不收费 |
| SNS（Email） | ~$0.00/月 | 每月前 1,000 封邮件 |
| CloudWatch 自定义指标 | $0.30/月 | 每月 10 个指标免费 |
| CloudWatch Alarm | $0.10/月 | 每月 10 个标准 Alarm 免费 |
| CloudWatch Logs | $0.50/GB 采集 + $0.03/GB 存储 | 每月 5GB 免费 |
| **总计** | **~$0.40/月** | 若免费额度未用完则接近 $0 |

> 巡检每日执行一次，Lambda 运行 < 2 秒，日志量 < 1KB/次。实际日志存储取决于保留期设置。

---

## 本地测试

```bash
# 安装 uv（如未安装）: https://docs.astral.sh/uv/
uv run --with pytest --no-project -- python -m pytest tests/ -v
```

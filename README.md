# EFS Cross-VPC Access Using PHZ

使用 Route 53 Private Hosted Zone (PHZ) 实现跨 VPC 的 EFS 文件系统访问。

> **Disclaimer / 免责声明**
>
> 本项目中的代码和文档仅供参考和学习用途。作者不对代码的质量、安全性、可靠性或适用性做任何保证。使用者应自行评估风险，并在生产环境使用前进行充分的测试和审查。因使用本项目代码造成的任何损失，作者不承担任何责任。
>
> This project is provided for reference and educational purposes only. The author makes no warranties regarding the quality, security, reliability, or fitness for any particular purpose. Users should evaluate risks independently and conduct thorough testing before production use. The author assumes no liability for any damages arising from the use of this code.

---

## 1. 方案背景

### 问题

EFS 的 DNS 名（`fs-xxx.efs.<region>.amazonaws.com`）**仅在拥有 Mount Target 的 VPC 内部可以解析**。当您通过 VPC Peering 或 Transit Gateway 连接两个 VPC 时，消费者 VPC 中的实例无法通过 DNS 名直接挂载源 VPC 的 EFS：

```
VPC-A (EFS 源)                      VPC-B (消费者)
┌─────────────────┐                 ┌─────────────────┐
│ EFS: fs-xxx     │  VPC Peering    │ EC2 / EKS Pod   │
│ Mount Target    │◄───── active ──►│                  │
│  us-east-1a     │                 │ nslookup fs-xxx  │
│  IP: 10.0.1.17  │                 │ → NXDOMAIN ✗     │
└─────────────────┘                 └─────────────────┘
```

`mount -t nfs4 fs-xxx.efs.<region>.amazonaws.com:/ /mnt` 因 DNS 解析失败而报错。

### PHZ 方案

创建一个 Private Hosted Zone（域名 `efs.<region>.amazonaws.com`），关联到消费者 VPC，在其中添加 A 记录将 EFS DNS 名指向 Mount Target IP。消费者 VPC 的 DNS Resolver 会优先查询 PHZ，从而获得正确的 IP：

```
VPC-A (EFS 源)                      VPC-B (消费者)
┌─────────────────┐                 ┌─────────────────────────┐
│ EFS: fs-xxx     │  VPC Peering    │ EC2 / EKS Pod           │
│ Mount Target    │◄───── active ──►│                         │
│  us-east-1a     │                 │ nslookup fs-xxx         │
│  IP: 10.0.1.17  │◄── NFS 2049 ───│ → 10.0.1.17 ✓ (PHZ)    │
│                 │                 │                         │
│ (不关联 PHZ)     │                 │ PHZ: efs.<region>.a.c.  │
│                 │                 │   fs-xxx → 10.0.1.17    │
└─────────────────┘                 └─────────────────────────┘
```

### 方案特点

| 特点 | 说明 |
|------|------|
| 成本低 | PHZ ~$0.50/月 + $0.40/百万次查询 |
| 无额外基础设施 | 不需要 Resolver Endpoint（节省 ~$180/VPC/月） |
| 对应用透明 | 挂载命令与同 VPC 完全一致 |
| 限制 | 源 VPC（有 EFS MT 的 VPC）不能关联此 PHZ（`ConflictingDomainExists`） |
| 限制 | 消费者 VPC 自身不能有 EFS Mount Target（同域名冲突） |

---

## 2. 方案设计

### A 记录策略

根据 EFS 的 Mount Target 数量，使用不同的 A 记录策略：

| 场景 | Mount Target 数量 | 创建的 A 记录 | 原因 |
|------|-------------------|--------------|------|
| 场景一 | 1 个（单 AZ） | generic (`fs-xxx.efs...`) + per-AZ (`az.fs-xxx.efs...`) | 单 MT 无跨 AZ 问题，generic 记录方便标准工具直接使用 |
| 场景二 | ≥2 个（多 AZ） | 仅 per-AZ 记录 | PHZ A 记录是静态值，generic 记录会导致跨 AZ 流量 ($0.01/GB) |
| 异常 | 状态非 available | 不创建记录 | 异常 MT 不应作为 DNS 目标 |

### 运维闭环设计

本项目提供从 Day 1 配置到 Day 2 运维的完整工具链：

```
┌──────────────────────────────────────────────────────────────────────┐
│                         完整运维闭环                                  │
│                                                                      │
│  1. 配置     手动配置 PHZ + 网络基础设施                               │
│     │        (docs/manual.md)                                        │
│     v                                                                │
│  2. 自动化   一键创建所有 EFS 的 A 记录                                │
│     │        (scripts/phz-auto-records.sh)                           │
│     v                                                                │
│  3. 验证     测试 DNS 解析连通性                                       │
│     │        (scripts/efs-dns-test.sh)                               │
│     v                                                                │
│  4. 巡检     每日自动检查 A 记录正确性                                  │
│     │        (audit/)                                                │
│     v                                                                │
│  5. 告警     发现问题 → 邮件通知 + CloudWatch 指标                     │
│     │                                                                │
│     v                                                                │
│  6. 修复     重新执行 phz-auto-records.sh → 回到步骤 3 验证            │
│              ↑________________________________________________↩      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 目录结构

```
efs-cross-vpc-access-using-phz/
├── README.md                       # 本文档（方案总览 + 完整链路说明）
├── LICENSE                         # MIT License
│
├── docs/
│   └── manual.md                   # PHZ 手动配置指南（完整步骤详解）
│                                   #   VPC Peering → 路由 → 安全组 → PHZ → A 记录
│
├── scripts/
│   ├── phz-auto-records.sh         # 一键创建 PHZ A 记录
│   │                               #   扫描源 VPC 所有 EFS，自动判断场景
│   ├── efs-dns-test.sh             # 单机 DNS 测试（在 EC2 上运行）
│   │                               #   自动获取实例信息，输出格式化表格
│   └── efs-dns-ssm-test.sh         # 多机 DNS 批量测试（通过 SSM 远程执行）
│                                   #   在多台 EC2 上并行测试，生成 Markdown 报告
│
└── audit/                          # PHZ 巡检 Lambda（日常自动化巡检）
    ├── README.md                   #   巡检工具部署手册 + 告警查收方式
    ├── deploy.sh                   #   一键部署脚本
    ├── template.yaml               #   CloudFormation 模板
    ├── audit_handler/              #   Lambda 入口
    ├── shared/python/              #   Lambda Layer（共享库）
    ├── tests/                      #   单元测试
    └── pyproject.toml              #   Python 项目配置
```

---

## 4. 快速开始

### 步骤一：配置网络基础设施

按照 [docs/manual.md](docs/manual.md) 完成以下配置：

1. 创建 VPC Peering（或确认已有 Transit Gateway 连接）
2. 配置双向路由（VPC-A 和 VPC-B 的路由表）
3. 配置安全组（EFS Mount Target SG 允许消费者 VPC 的 NFS 流量）
4. 创建 PHZ 并关联到消费者 VPC
5. 验证网络连通性（TCP 2049 端口测试）

> 详细的 CLI 命令、Console 操作说明和故障排查指南见 [docs/manual.md](docs/manual.md)。

### 步骤二：自动创建 A 记录

使用 `phz-auto-records.sh` 一键为所有 EFS 创建 PHZ A 记录：

```bash
# 预览（不实际创建）
bash scripts/phz-auto-records.sh \
  --phz-id <PHZ-ID> \
  --source-vpc <EFS所在VPC-ID> \
  --region us-east-1 \
  --dry-run

# 确认无误后正式执行
bash scripts/phz-auto-records.sh \
  --phz-id <PHZ-ID> \
  --source-vpc <EFS所在VPC-ID> \
  --region us-east-1
```

脚本会自动：
- 扫描源 VPC 中的所有 EFS 和 Mount Target
- 判断单 MT / 多 MT 场景
- 创建对应的 A 记录（已存在的自动跳过）
- UPSERT 操作，可安全重复执行

### 步骤三：验证 DNS 解析

#### 方式一：单机测试（SSH 到 EC2 后运行）

编辑 `scripts/efs-dns-test.sh` 中的配置区，填入您的 EFS 信息，然后在 EC2 上执行：

```bash
bash efs-dns-test.sh
```

输出示例：

```
+-----------------------+------------------+--------------------------------------------------+---------+
| EFS 名称              | 查询类型          | DNS 名称                                          | 结果    |
+-----------------------+------------------+--------------------------------------------------+---------+
| My-Regional-EFS       | General DNS      | fs-0abc.efs.us-east-1.amazonaws.com               | PASS    |
| My-Regional-EFS       | AZ DNS (1a)      | us-east-1a.fs-0abc.efs.us-east-1.amazonaws.com    | PASS    |
| My-OneZone-EFS        | General DNS      | fs-0def.efs.us-east-1.amazonaws.com               | PASS    |
+-----------------------+------------------+--------------------------------------------------+---------+
```

#### 方式二：多机批量测试（本地通过 SSM 执行）

编辑 `scripts/efs-dns-ssm-test.sh` 中的配置区（实例 ID、EFS DNS 列表），然后在本地执行：

```bash
bash scripts/efs-dns-ssm-test.sh --region us-east-1
```

会在多台 EC2 上并行测试并生成 Markdown 对比报告。

### 步骤四：部署日常巡检

部署 Lambda 巡检工具，每日自动检查 A 记录正确性。

#### 部署参数

| 参数 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `--stack-name` | 是 | CloudFormation Stack 名称 | `efs-phz-audit` |
| `--s3-bucket` | 是 | Lambda 部署包的 S3 存储桶（需已存在） | `my-deploy-bucket` |
| `--phz-ids` | 是 | PHZ Hosted Zone ID，多个用逗号分隔 | `"Z0001ABC,Z0002DEF"` |
| `--efs-vpc-ids` | 是 | EFS 所在源 VPC ID，多个用逗号分隔 | `"vpc-aaa,vpc-bbb"` |
| `--alert-emails` | 是 | 告警邮箱，多个用逗号分隔 | `"a@example.com,b@example.com"` |
| `--schedule` | 否 | 巡检频率，默认 `rate(1 day)` | `"cron(0 2 * * ? *)"` |
| `--region` | 否 | AWS Region，默认 `us-east-1` | `us-west-2` |

#### 执行部署

```bash
cd audit/

./deploy.sh \
  --stack-name efs-phz-audit \
  --s3-bucket <YOUR-S3-BUCKET> \
  --phz-ids "<PHZ-ID>" \
  --efs-vpc-ids "<EFS所在VPC-ID>" \
  --alert-emails "ops@example.com" \
  --schedule "cron(0 2 * * ? *)" \
  --region us-east-1
```

#### 部署后操作

**1. 确认邮箱订阅**

部署后每个邮箱会收到 **AWS Notification - Subscription Confirmation** 邮件，**必须点击 "Confirm subscription" 链接**，否则无法收到告警通知。

> 提示：如果使用 QQ 邮箱等国内邮箱，建议复制确认链接到浏览器打开（避免邮箱安全扫描改写 URL）。

**2. 手动触发巡检验证部署是否正常**

部署完成后不会自动执行一次巡检，建议手动触发确认：

```bash
aws lambda invoke \
  --function-name efs-phz-audit-audit \
  --region us-east-1 \
  /tmp/result.json

cat /tmp/result.json | python3 -m json.tool
```

返回结果说明：
- `"audit_result": "ALL_GOOD"` — 所有 A 记录正确，不会发送邮件
- `"audit_result": "ISSUES_FOUND"` — 发现问题，会同时发送告警邮件

更多运维操作（添加/移除邮箱、暂停/恢复巡检、卸载）见 [audit/README.md](audit/README.md)。

### 步骤五：问题修复（当巡检发现问题时）

```bash
# 1. 收到告警邮件或在 CloudWatch 发现 IssueCount > 0

# 2. 重新执行 A 记录创建脚本修复
bash scripts/phz-auto-records.sh \
  --phz-id <PHZ-ID> \
  --source-vpc <EFS所在VPC-ID> \
  --region us-east-1

# 3. 手动触发巡检确认修复结果
aws lambda invoke --function-name efs-phz-audit-audit --region us-east-1 /tmp/verify.json
cat /tmp/verify.json | python3 -m json.tool
# 期望: "audit_result": "ALL_GOOD"
```

> 对于过期记录（stale），需在 Route 53 控制台或通过 CLI 手动删除。

---

## 5. 巡检告警查收方式

| 方式 | 说明 | 适用场景 |
|------|------|---------|
| **邮件** | 仅发现问题时发送，包含问题详情和修复建议 | 日常运维，第一时间响应 |
| **CloudWatch 指标** | `EFS/PHZAudit` / `IssueCount`，每次都发（含 0） | 趋势分析，Dashboard 可视化 |
| **CloudWatch Alarm** | `{stack-name}-issues-detected`，ALARM/OK 状态 | 控制台快速查看健康状态 |
| **Lambda 日志** | 完整的 JSON 结构化结果 | 故障排查，对接监控系统 |

详细查看方式见 [audit/README.md](audit/README.md#巡检结果查收)。

---

## 6. 成本估算

### PHZ 方案本身

| 资源 | 费用 | 说明 |
|------|------|------|
| Private Hosted Zone | $0.50/月/zone | 前 25 个 zone；之后 $0.10/zone |
| DNS 查询（PHZ） | **免费** | Private Hosted Zone 查询不收费 |
| A 记录 | 免费 | 每个 zone 前 10,000 条记录不收费 |

> **注意**：$0.40/百万次查询 是**公共托管区**的价格，Private Hosted Zone 查询免费。

### 巡检工具（可选）

| 资源 | 费用 | 免费额度 |
|------|------|---------|
| Lambda | ~$0.00/月 | 每月 100 万次请求 + 40 万 GB-秒免费 |
| EventBridge | ~$0.00/月 | 定时规则触发不收费 |
| SNS（Email） | ~$0.00/月 | 每月前 1,000 封邮件免费 |
| CloudWatch 自定义指标 | $0.30/月 | 每月 10 个指标免费 |
| CloudWatch Alarm | $0.10/月 | 每月 10 个标准 Alarm 免费 |
| CloudWatch Logs | $0.50/GB 采集 + $0.03/GB 存储 | 每月 5GB 免费 |
| **巡检工具总计** | **~$0.40/月** | 若免费额度未用完则接近 $0 |

> 巡检工具每日执行一次，Lambda 运行时间 < 2 秒，日志量 < 1KB/次。对于新账号或资源较少的账号，大部分费用在免费额度内。

### 数据传输（使用 EFS 时产生）

| 场景 | 费用 | 说明 |
|------|------|------|
| 同 AZ 访问 | 免费 | 消费者实例与 Mount Target 在同一 AZ |
| 跨 AZ 访问 | $0.01/GB/方向 | 消费者实例与 Mount Target 在不同 AZ |
| 跨 VPC（VPC Peering） | 同 AZ 免费，跨 AZ $0.01/GB | VPC Peering 本身不收费 |
| 跨 VPC（Transit Gateway） | $0.02/GB + ~$36/月/attachment | TGW 有固定的 attachment 费用 |

> 这不是 PHZ 方案本身的费用，但在规划跨 VPC EFS 访问时需要考虑。多 MT EFS 建议使用 per-AZ DNS 记录（`az.fs-xxx.efs...`）以避免跨 AZ 流量。

---

## 7. 常见问题

### Q: 源 VPC（有 EFS 的 VPC）能关联 PHZ 吗？

不能。AWS 为有 Mount Target 的 VPC 自动创建了内部 PHZ（同域名 `efs.<region>.amazonaws.com`），再关联用户 PHZ 会报 `ConflictingDomainExists`。源 VPC 有原生 EFS DNS，不需要 PHZ。

### Q: 消费者 VPC 自身有 EFS 能用此方案吗？

不能。原因同上 — 消费者 VPC 有 EFS MT 时也会有内部 PHZ，无法关联用户 PHZ。此时可使用 IP 直接挂载方式。

### Q: 多 MT EFS 为什么不创建 generic 记录？

PHZ A 记录是静态值。如果 generic 记录固定指向某个 AZ 的 IP，其他 AZ 的实例访问时会产生跨 AZ 流量（$0.01/GB）。PHZ 不支持 AZ 级别的路由策略，因此多 MT 场景只创建 per-AZ 记录，由客户端显式指定目标 AZ。

### Q: Mount Target IP 变了怎么办？

重新运行 `phz-auto-records.sh`，脚本使用 UPSERT 操作会自动更新记录。如果部署了巡检工具，IP 变化会被检测为 `ip_mismatch` 并通过邮件告警。

### Q: Schedule 表达式支持哪些格式？

- Rate 表达式：`rate(1 day)`, `rate(12 hours)`
- Cron 表达式：`cron(分 时 日 月 星期 年)`，注意日和星期不能同时为 `*`
  - `cron(0 2 * * ? *)` = 每天 UTC 02:00
  - `cron(0 18 * * ? *)` = 每天 UTC 18:00（北京时间次日 02:00）
  - `cron(0 2 ? * MON *)` = 每周一 UTC 02:00

---

## License

MIT License. See [LICENSE](LICENSE).

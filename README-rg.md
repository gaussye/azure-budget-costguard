# Azure 预算成本守卫 · 资源组版(Cost-Guard for Resource Group)

Windows CMD 脚本,为**整个资源组**配置自动**成本止损开关**。

当资源组的**月度总消费**超过预算阈值时,Azure 会自动禁用该资源组下**所有 foundry
资源**(`Microsoft.CognitiveServices/accounts`,`kind = AIServices`)的**本地(密钥)
认证**(`properties.disableLocalAuth = true`),阻止继续通过密钥调用、防止成本失控。

> 这是 [`setup-budget-costguard.cmd`](./README.md)(单资源版)的**资源组版**变体。
> 区别:预算作用于整个资源组,触发时批量禁用组内所有 foundry 资源的密钥。

```
预算告警(资源组月度总花费达到阈值)
      │
      ▼
Action Group(Automation Runbook 接收器)
      │   └─ 底层通过 runbook 的 webhook URL(serviceUri)触发
      ▼
Automation Runbook  "DisableLocalAuth-<资源组名>"
      │   └─ 使用 Automation Account 的系统分配托管身份
      │   └─ 枚举 RG 内所有 kind=AIServices 的 foundry 账号
      ▼
对每个 foundry 账号:ARM PATCH  →  properties.disableLocalAuth = true
```

> 说明:Action Group 本身**不能直接执行 CLI 命令**,只能把事件投递给接收器。
> 因此事件被路由到 **Automation Runbook**,由它用托管身份运行 PowerShell 完成禁用。
> Runbook 通过其 **webhook URL** 触发。此外,Azure Automation 沙箱**不含 `az` CLI**,
> 所以 runbook 直接调用 ARM(列举 + PATCH),等价于 `az resource update`。

## 前置条件

- 已安装并登录 [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli):
  ```cmd
  az login
  ```
- 具备创建资源和分配角色的权限(目标资源组的 Owner / User Access Administrator)。
- 目标**资源组**需已存在(组内 foundry 资源可有可无——触发时按当时实际存在的枚举)。

## 用法

```cmd
setup-budget-costguard-rg.cmd <resource-group> [budget-amount] [threshold-percent] [alert-email]
```

| 参数                  | 必填 | 说明                                          | 默认值             |
|-----------------------|------|-----------------------------------------------|--------------------|
| `<resource-group>`    | 是   | 要守护的**资源组名称**                        | —                  |
| `[budget-amount]`     | 否   | 月度预算金额                                  | `50`               |
| `[threshold-percent]` | 否   | 告警阈值(预算的百分比)                      | `90`               |
| `[alert-email]`       | 否   | 接收预算通知的邮箱                            | `you@example.com`  |

### 示例

```cmd
:: 默认(预算 50,90% 告警,默认邮箱)
setup-budget-costguard-rg.cmd rg-admin-3283

:: 预算 10000,80% 告警
setup-budget-costguard-rg.cmd rg-admin-3283 10000 80

:: 预算 10000,80% 告警,指定通知邮箱
setup-budget-costguard-rg.cmd rg-admin-3283 10000 80 ops@contoso.com
```

预算**直接作用于整个资源组**——组内所有资源的花费之和触发告警。

## 配置

编辑 `setup-budget-costguard-rg.cmd` 顶部的变量块:

| 变量                     | 用途                                              |
|--------------------------|---------------------------------------------------|
| `SUBSCRIPTION`           | 目标订阅(留空 = 使用当前 `az` 上下文)            |
| `INFRA_RG`               | 存放 Automation Account 的资源组                  |
| `LOCATION`               | 基础设施资源的区域                                |
| `COG_API_VERSION`        | 列举 / PATCH Cognitive 账号所用的 API 版本(默认 `2026-05-01`) |
| `BUDGET_AMOUNT` / `BUDGET_THRESHOLD` / `ALERT_EMAIL` | 默认值(可被参数 2、3、4 覆盖) |
| `FOUNDRY_KIND`           | 被识别为 foundry 的账号 `kind`(默认 `AIServices`) |
| `AUTOMATION_PREFIX` / `ACTION_GROUP_PREFIX` / `RUNBOOK_PREFIX` | 命名前缀     |
| `SET_DISABLE_LOCAL_AUTH` | `true` = 禁用密钥(默认);`false` = 启用密钥      |

> ⚠️ **`disableLocalAuth=true` 表示禁用密钥。** 仅当你想要相反行为时,才设为
> `SET_DISABLE_LOCAL_AUTH=false`。

## 创建的资源

以资源组名 `rg-admin-3283` 为例,脚本会创建:

| 资源                | 名称                                    | 位置              |
|---------------------|-----------------------------------------|-------------------|
| Automation Account  | `aa-cg-rg-admin-3283`                   | `INFRA_RG`        |
| Runbook             | `DisableLocalAuth-rg-admin-3283`        | `INFRA_RG`        |
| Webhook             | `DisableLocalAuth-rg-admin-3283-wh`     | `INFRA_RG`        |
| Action Group        | `ag-cg-rg-admin-3283`                   | `INFRA_RG`        |
| Budget              | `costguard-rg-admin-3283`               | 目标资源组(范围=整个 RG) |
| 角色分配            | 为 Automation Account 的托管身份授予 *Cognitive Services Contributor* | 目标**资源组**上 |

> 与单资源版不同:角色分配授予在**整个资源组**上,这样 runbook 才能 PATCH 组内
> 任意 foundry 账号;预算也**不带 ResourceId 过滤**,统计的是整组花费。

## 费用说明

这套链路是**事件驱动**的——平时只是几条配置记录,不产生持续费用。整体成本**几乎为 0**。

| 组件 | 计费方式 | 实际花费 |
|------|----------|----------|
| Budget(预算)        | Cost Management 预算功能免费                       | ¥0 |
| Action Group          | 创建/存在不收费;仅按发出的通知计费(Runbook 动作本身不收费) | ¥0 |
| Automation Account    | 账号本身不收费                                     | ¥0 |
| Runbook 作业          | 每月前 **500 分钟免费**,超出约 **$0.002/分钟**     | 每次触发仅几秒,几乎 ¥0 |
| Webhook               | 免费                                               | ¥0 |
| 角色分配 / 托管身份   | 免费                                               | ¥0 |

> 唯一可能计费的是 Automation 作业时长,但每次禁用密钥的运行只需数秒,即使一个月
> 触发上千次也远在 500 分钟免费额度内,实际仍是 0。

需要留意:

- **通知类动作**:若你在 Action Group 中加入短信/语音通知,会有少量费用(邮件每月前 1000 封免费)。当前脚本只用 Runbook 动作 + 邮件通知。
- **被保护的资源本身**(foundry 账号)照常按其自身用量计费——本脚本不增加它的成本,反而是用来帮你**止损**的。
- 价格随区域与时间变动,以你订阅的实际账单为准。

## 幂等性

脚本可安全重复运行:

- **角色分配** —— 先检查,已存在则跳过。
- **Runbook** —— 不存在才创建;内容总是替换并发布。
- **Webhook** —— 删除后重建(webhook URI 一次性、不可更新)。
- **Action Group / Budget / 身份** —— PUT/PATCH 覆盖(天然幂等)。

> 由于 webhook URI 不可更新,**每次运行都会轮换 webhook URL**。脚本会自动把新 URL
> 同步进 Action Group,所以告警链路始终有效——但你之前手动保存的测试 URL 会失效。

## 测试成本守卫

成本数据有正常的 Azure 延迟(数小时),因此真实预算触发不是即时的。要立即验证链路,
可对运行结束时输出的 webhook URL 发起 POST:

```cmd
curl -X POST "<WEBHOOK_URI>"
```

然后验证组内 foundry 资源是否被禁用:

```cmd
:: 在门户查看 runbook 作业历史:
::   Automation Account -> Runbooks -> DisableLocalAuth-<资源组名> -> Jobs

:: 或逐个检查资源状态:
az cognitiveservices account show -n <account-name> -g <resource-group> --query "properties.disableLocalAuth"
```

作业输出会逐行列出每个被处理的账号,例如
`admin-3283-resource: disableLocalAuth is now True`。

## 人工启用 key

告警导致 key 不可用,需要恢复到可用状态。由于本工具作用于**整个资源组**,恢复时
同样应**枚举 RG 下所有 foundry 资源再逐个 enable**(enable 会激活 key 为可使用状态,
但不会更新 key):

在命令行直接运行(`%n` 单百分号):

```cmd
for /f "usebackq delims=" %n in (`az cognitiveservices account list -g ^<resource-group^> --query "[?kind=='AIServices'].name" -o tsv`) do az resource update -g ^<resource-group^> --name %n --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false
```

> 若把上面这段写进 `.cmd` 批处理文件,需把 `%n` 改成 `%%n`。

PowerShell 版本:

```powershell
az cognitiveservices account list -g <resource-group> --query "[?kind=='AIServices'].name" -o tsv |
  ForEach-Object {
    az resource update -g <resource-group> --name $_ --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false
  }
```

如只想恢复**单个**资源:

```cmd
az resource update --resource-group <resource-group> --name <account-name> --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false
```

## 清理

删除脚本为某个资源组创建的全部内容:

```cmd
:: 删除预算
az rest --method delete --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<target-rg>/providers/Microsoft.Consumption/budgets/costguard-<资源组名>?api-version=2023-11-01"

:: 删除 action group
az monitor action-group delete --name ag-cg-<资源组名> --resource-group <infra-rg>

:: 删除角色分配(用 Automation Account 托管身份的 principalId)
az role assignment delete --assignee <principalId> --role "Cognitive Services Contributor" --scope /subscriptions/<sub>/resourceGroups/<target-rg>

:: 删除 automation account(连带 runbook + webhook)
az automation account delete --name aa-cg-<资源组名> --resource-group <infra-rg> --yes
```

## 说明与限制

- 触发动作只作用于 **`Microsoft.CognitiveServices/accounts` 且 `kind = AIServices`**
  的 foundry 账号;组内其它类型资源(OpenAI、SpeechServices、CustomVision 等)不受影响。
  如需覆盖其它 kind,修改脚本顶部的 `FOUNDRY_KIND`。
- 写入 runbook 的是**资源组名**(而非某个静态 resource id)——触发时**动态枚举**当时
  组内的 foundry 账号,新增/删除资源无需重跑脚本。
- 某些账号可能被 Azure Policy 强制锁定为 `disableLocalAuth=true`,这种情况下没有可
  翻转的状态。

## 许可证

MIT

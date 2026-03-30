# CF-DDNS

面向 ARM 路由器的 Cloudflare DDNS 优选工具。

它做的事情很单一：周期性测速 Cloudflare 节点，挑出当前最优 IP，把结果同步到 Cloudflare DNS，并提供一个轻量状态面板。

## 定位

- 目标平台：ARM64 软路由、树莓派、ARM 小主机
- 部署方式：Docker
- 目标场景：需要把一个或多个域名的 A/AAAA 记录持续收敛到当前较优的 Cloudflare 节点
- 非目标：通用多平台 DDNS、复杂多云适配、重型监控系统

## 功能

- 单次测速，多域名分发
- 支持 IPv4 / IPv6
- Cloudflare API 失败自动重试
- 熔断保护，避免高延迟结果误推
- 金丝雀更新，降低批量切换风险
- 超额记录自动收敛
- 智能调度间隔
- Web 状态面板
- 手动触发一轮全量扫描

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/VonPeii/cf-ddns.git
cd cf-ddns
```

### 2. 下载 ARM64 版测速工具

当前仓库默认按 `ARM64` 构建。请把 CloudflareST 的 ARM64 压缩包放到项目根目录，文件名保持和 Dockerfile 一致。

```bash
wget -O cfst_linux_arm64.tar.gz https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.2.5/CloudflareST_linux_arm64.tar.gz
```

### 3. 准备配置

```bash
cp .env.example .env
```

编辑 `.env`：

```env
DOMAIN_1_NAME=blog.example.com
DOMAIN_1_ZONE_ID=your_zone_id
DOMAIN_1_TOKEN=your_api_token

DOMAIN_2_NAME=cdn.example.net
DOMAIN_2_ZONE_ID=your_zone_id
DOMAIN_2_TOKEN=your_api_token
```

域名编号允许不连续，例如只配置 `DOMAIN_1_*` 和 `DOMAIN_3_*` 也可以。

### 4. 启动

```bash
docker compose up -d --build
```

### 5. 打开面板

默认地址：

```text
http://你的路由器IP:8088
```

## 首次启动会发生什么

- 容器先校验配置和依赖
- Web 面板先起来
- 第一轮测速开始执行
- 如果第一轮没有拿到有效结果，面板会继续显示空状态或历史有效结果，不会乱写 DNS
- 一旦拿到有效结果，后续状态页会展示候选 IP、延迟和历史曲线

## 配置参考

### `docker-compose.yml` 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `INTERVAL` | `86400` | 基础测速间隔，单位秒 |
| `CFST_TL` | `250` | 延迟上限，单位 ms |
| `CFST_SL` | `5` | 速度下限，单位 MB/s |
| `IP_COUNT` | `5` | 每种记录类型的目标保留数量 |
| `CFST_URL` | `https://speed.cloudflare.com/__down?bytes=50000000` | 测速目标 URL |
| `ENABLE_IPV4` | `true` | 是否测速并同步 A 记录 |
| `ENABLE_IPV6` | `true` | 是否测速并同步 AAAA 记录 |
| `ABORT_LATENCY` | `300` | 熔断阈值，超过则拒绝更新 |
| `CANARY_MODE` | `true` | 是否启用金丝雀更新 |
| `CANARY_MAX_CHANGES` | `1` | 每轮最多推进多少条替换 |
| `API_MAX_RETRIES` | `3` | Cloudflare API 最大重试次数 |
| `API_BASE_DELAY` | `5` | API 重试基础等待秒数 |
| `SMART_INTERVAL` | `true` | 是否启用智能调度 |
| `SMART_STABLE_THRESHOLD` | `3` | 连续稳定多少轮后放大间隔 |
| `MAX_INTERVAL` | `172800` | 智能调度允许的最大间隔 |
| `WEB_PORT` | `8088` | Web 面板端口 |
| `HISTORY_MAX` | `200` | 历史记录保留条数 |

### `.env` 凭据

| 变量 | 说明 |
|------|------|
| `DOMAIN_N_NAME` | 第 N 个域名 |
| `DOMAIN_N_ZONE_ID` | 该域名所属 Zone ID |
| `DOMAIN_N_TOKEN` | 具有 DNS 编辑权限的 API Token |

## 启动前校验

容器启动时会直接校验以下内容，发现问题会报错退出：

- 缺少 `curl`、`jq`、`httpd`、`awk`、`sort` 等依赖命令
- `/app/cfst` 不存在或不可执行
- 关键数值配置不是正整数
- 布尔开关不是 `true` 或 `false`
- `ENABLE_IPV4` 和 `ENABLE_IPV6` 同时关闭
- `MAX_INTERVAL < INTERVAL`
- `ABORT_LATENCY < CFST_TL`
- 域名配置为空
- `ZONE_ID` 或 `TOKEN` 仍然是示例值

## DNS 同步策略

每轮测速结束后，脚本会把 Cloudflare 记录收敛到本轮目标状态：

- 候选 IP 先去重
- 每种记录类型的目标数量等于本轮有效候选 IP 数，通常就是 `IP_COUNT`
- 不在目标集合中的旧记录会删除
- 如果 Cloudflare 里已有记录数超过目标数量，多出来的记录会逐轮自动收敛
- `CANARY_MODE=true` 时，`CANARY_MAX_CHANGES=1` 表示每轮最多替换 1 条记录，不是只做 1 次 API 调用
- 如果本轮测速没有得到有效结果，脚本保留上一次有效结果，不强行写入空记录

## 日志与异常行为

当前日志按这几个类别输出：

- `INFO`：启动、测速成功、DNS 变更、休眠、调度
- `WARN`：测速无有效结果、熔断、超额记录收敛、删除旧记录失败
- `ERROR`：Cloudflare API 最终失败、域名查询失败、启动校验失败

几个关键异常路径的行为如下：

- 首次启动没有测速结果：状态页保持空状态，不乱写 DNS
- 测速程序异常退出：保留上次有效结果
- 本轮测速结果为空：保留上次有效结果
- Cloudflare API 查询或写入失败：记录错误日志，本轮仅跳过受影响域名
- 记录数量异常偏多：后续轮次自动收敛

## 常用命令

```bash
docker compose logs -f
docker compose up -d
docker compose up -d --build
docker compose down
```

## 常见问题

### 1. 面板能打开，但一直没有数据

先看日志：

```bash
docker compose logs -f
```

重点检查：

- `cfst_linux_arm64.tar.gz` 是否正确放在项目根目录并已被打进镜像
- `DOMAIN_N_*` 是否填对
- 当前网络环境下 CloudflareST 是否能跑出有效结果
- `CFST_TL` / `CFST_SL` 是否设得过严

### 2. 为什么没有立刻更新 DNS

常见原因：

- 本轮测速没有有效 IP
- 触发了熔断保护
- 金丝雀模式下本轮只推进一部分变更
- 当前 Cloudflare 记录已经和目标状态一致

### 3. 为什么记录数一开始比 `IP_COUNT` 多

如果历史上已经堆积了多余记录，脚本不会一次性全删，而是按当前同步策略逐轮收敛，避免过于激进。

## 项目结构

```text
cf-ddns/
├── .env.example
├── Dockerfile
├── docker-compose.yml
├── update.sh
├── healthcheck.sh
└── web/
    ├── index.html
    └── cgi-bin/
        └── trigger.sh
```

## 致谢

测速能力来自 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)。

## License

[MIT](LICENSE)

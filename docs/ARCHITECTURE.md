# QuotaDock 架构说明

QuotaDock 是 AppKit 菜单栏应用。应用通过子进程桥连接本机 Codex helper，规范化额度响应，更新 SwiftUI/Combine 状态，记录本机历史，并由 AppKit 窗口绘制额度和趋势。

## 数据路径

<pre><code>Codex helper: app-server
        │ JSON-RPC over stdin/stdout
        ▼
QuotaBridge ──► QuotaStream ──► QuotaModel / QuotaForecast
                      │                     │
                      │                     ├──► WidgetHost
                      │                     ├──► StatusBarHost
                      │                     └──► TimelineWindow / TimelinePlot
                      ▼
                UsageLedger ──► 本机 JSONL（按天）
                      │
                      └──► ResetMoments / AlertRulebook</code></pre>

## 主要模块

### QuotaBridge 与 QuotaStream

QuotaBridge 启动 helper 的 app-server 子进程，通过 stdin/stdout 的换行 JSON-RPC 交换消息，单独读取并丢弃 stderr，避免诊断管道阻塞，也避免把潜在账号信息落入应用日志。每条请求有超时；退出或卡死时让等待中的请求失败，由 QuotaStream 按 15、30、60、120、300 秒退避重连。

QuotaStream 是唯一与 QuotaBridge 通信的层。它处理启动、账号状态、定期拉取、服务端更新通知、手动刷新和重连；视图只订阅已发布的额度模型。

### QuotaModel

QuotaDecoder 兼容分组 rateLimitsByLimitId 与旧式单组 rateLimits 响应，并规范化为额度组和短/长窗口。主额度优先选 Codex 组；窗口剩余百分比由已用百分比反算并限制在 0–100。

### QuotaForecast

对最近 20 分钟窗口拟合，无法判断时回退到 1 小时。最少 4 个点、最短跨度 4 分钟，允许的最大采样间隔 20 分钟，最低下降阈值每分钟 0.02 个百分点。输出 collecting、steady、exhausted 或 falling 四种明确状态。

额度耗尽造成其他额度被阻挡时，模型保存阻挡前速度并平移预计耗尽时间；这样不会将阻挡期间的水平采样误拟合成零速度。绘图层还会依据更长窗口与重置时刻决定预测线何时截断或归零。

### UsageLedger 与 ResetMoments

每次成功刷新最多每 25 秒写入一次。按日期分 JSONL 文件，记录采样 Unix 时间戳和额度窗口的剩余值、重置时间。保留 45 天；过期账本在启动时删除。磁盘写入使用独立低优先级队列，界面从内存缓存读取曲线。

重置识别寻找从低值回升至约 95%、且相对上一采样至少上升 10 个百分点的跳变。同一 2 分钟范围内不同窗口的标记合并，避免重复画同一重置。

### 界面层

WidgetHost 负责桌面浮窗、吸附和跨 Space 行为；StatusBarHost 负责状态栏摘要、菜单和全局快捷键；TimelineWindow / TimelinePlot 负责历史曲线、缩放、重置线和日期刻度。Preferences 保存主题、语言、采样间隔、提醒和窗口行为。

## 本机持久化

| 内容 | 本机位置 |
|---|---|
| 界面、提醒、采样间隔等偏好 | UserDefaults，Bundle ID com.quotadock.app |
| 额度历史 | Application Support/QuotaDock/Ledger，按天 JSONL，最多保留 45 天 |
| Codex helper 独立工作区 | Application Support/QuotaDock/Codex，默认设置 CODEX_HOME |

额度账本存储剩余比例和重置时间，不记录聊天正文。helper 通过 app-server 与 Codex 服务交互，其账号与网络行为属于 Codex helper 的产品范围。

## 构建与运行时边界

build.sh 使用 xcrun 与 swiftc 构建 arm64、macOS 14 App Bundle，并将开发者本地提供的 Codex helper 复制到 Contents/Helpers/codex。仓库不携带该可执行文件。helper app-server 的消息和额度字段不是公开兼容性承诺，Codex 更新可能导致适配失效。

默认 ad-hoc 签名不等于 Apple Developer ID 签名或公证。将 QuotaDock.app 安装到 /Applications 需要用户显式传入 install 参数；构建脚本先备份已有 App 到本地 build/prev.app。

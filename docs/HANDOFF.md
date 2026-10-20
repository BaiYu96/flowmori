# Flowmori 交接（2026-10-20，构建 10）

## 当前状态

继续现有项目 `/Users/baiyu/Documents/macflow`，不要重建工程。Swift/AppKit/SwiftUI，MIT，本机数据；无 Git 仓库，不公开发布。不要开启多代理，除非用户明确请求。用户希望集中修改、一次安装，减少重复测试与 TCC 授权。

固定安装位置 `/Users/baiyu/Applications/Flowmori.app`，当前 0.1.0／10；dist 复用同一签名产物。可执行 SHA256：`c8e796128da65833255ce966815cce5c7fef9c9498ed0abdda55672a3a63ebd3`。不要无故重新签名。应用 ZIP 与源码 ZIP 在 dist；package.sh 只打包、不重签。

构建 10 初始心跳 `.validation/heartbeat-flowmori-build10.json` 两项权限 false，已通过聊天异步问题请用户恢复辅助功能和屏幕录制权限。用户回复后先核实当前进程与心跳：用户可能手动重启应用，旧心跳会过期；可以重开同一个已授权安装包并传入 `--diagnostics`，不重签、不再索要相同授权。初始 PID 90963 仅供查证，禁止未核对身份就发送信号。

## 已实现与真实证据

- 一键「收纳全部」自动定位 Flowmori 入口和分隔符，把所有已识别可管理图标移入收纳；系统项、未知项保留。新应用通过生命周期与轮询自动接纳；主动展开停止自动收纳。未知/冲突/操作失败安全展开。临时菜单操作与全量整理独立。
- 归属缓存保留临时 AX 缺失，宿主指纹／源进程启动时间／系统项变化和冲突失效；实际输入前仍原应用 AX 重新校验。
- 构建 9 **真实成功收纳 10 个图标**，入口及系统项可见：`.validation/build9-collect-positioned-proof.json`。但首次布局误判失败，普通菜单归位顺序也未通过，**不能标为完成验收**。
- 高频坐标证明系统动画超过原来的 250ms，且刘海范围 x=665…850 造成邻居在两侧换位：`.validation/build9-menu-layout-trace.jsonl`、`build10-placement-trace.json`。只增加等待／补充拖动事件都不足以解决 notch 插入，不要重复走这些已失败的独立方案。
- 专用 QA 占位项把目标移出刘海后，同一归位算法成功相邻：`.validation/build10-notch-clear-placement.json`，最终 source x549 width52、neighbor x601 width64。该探针只证明关键几何路径，不代表安装产品端到端通过。
- 构建 10 合并修正：连续三次布局一致才继续；完整拖动事件；在收起状态记录原始逻辑邻居；归位时按源图标与邻居宽度临时加宽自有 divider，让插入区域位于刘海外。已在 divider 左侧的图标不重复拖动。自有入口/分隔符不可达时，先重显至可见插槽，再用真实窗口相邻校正。Preferred Position 不是全局坐标，禁止再用固定坐标公式直接定位。
- 构建 10 受影响自动测试 **17 项／4 组通过**：`.validation/build10-menu-tests.log`、`docs/menu-build10-tests.log`；Release/签名通过 `.validation/build10-release.log`。未重复运行无关模块全套测试。

## 下一步（未完成）

1. 用户恢复构建 10 权限后，确认未锁屏与当前心跳。直接验收安装版，不先改代码或重签。
2. 通过 Flowmori 产品入口验证一键收纳；专用夹具验证普通菜单／弹窗／右键后的原始顺序与稳定收起；再验证新图标自动纳入。脚本 `scripts/qa/menu-acceptance.py`，其入口假设收纳面板最初关闭且已能列出夹具。
3. 菜单通过后启动最终两小时独立监测。不要用旧构建／单元测试／短时状态替代通过。最终版本的注销登录、权限撤销、睡眠恢复等仍待验收。用户没有外接显示器，真实外接屏测试标为缺少条件。
4. 更新 VALIDATION 和本交接，再打包；相同签名不需重建。

## 文件与工具

`Sources/Flowmori/MenuBarBackend.swift` 为系统桥接、所有权、操作状态；`Sources/FlowmoriCore/MenuWindowResolver.swift` 为几何与布局稳定判断；`MenuAccessibilityCatalog.swift` 枚举原应用 AX。UI/README 已去除手动拖分隔符要求。`collectionStage`/`lastOperationOutcome` 可诊断失败阶段；QA helper 还输出 placementTrace。

命令：`bash scripts/swift-command.sh test --filter 'MenuWindowResolverTests|MenuCollectionTests|MenuLayoutStabilityTests|MenuNotchReturnTests'`；构建 `scripts/build-app.sh release`；直接复制已有 dist 安装可避免 install.sh 再次签名；`scripts/package.sh` 打包。

用户已明确允许按 `docs/UI-TEST-PLAN.md` 使用本地 AX／系统事件脚本，只操作 Flowmori、专用文档、专用菜单夹具；不点击其他应用业务菜单或系统状态项。通过产品“收纳全部”整理图标是当前用户要求。锁屏停止输入，不解锁、不修改 TCC。宿主是 ChatGPT.app，内部可能仍显示 codex。QA CLI 必须使用包外 `.validation/FlowmoriQAHelper`，不要启动夹具 bundle 内 CLI，以免产生误导的应用退出通知。脚本权限与产品权限分别核实。

原专用夹具可能仍 PID 87198（先验证）；它保留三类测试图标。`scripts/qa/build.sh` 会重建 helper 与夹具，但不会重签安装产品。测试脚本日志在 `.validation`，不收入源码 ZIP。测试失败两次且无新证据就换诊断策略。

## 沿用的历史验收

构建 7 全套 41 项／5 组通过（`docs/automated-tests.log`）。剪贴板、截图、贴图、快捷键、迁移、登录注册等实现及实测记录见 `docs/VALIDATION.md`，无关部分不要重复全套测试。

构建 5 三类菜单两轮通过（`build5-menu-stable-proof.json`、`build5-menu-stable-repeat.json`），后续版本发现新问题，不可替代最终验收。构建 6 超时／源应用退出恢复通过。构建 4 完整 7200 秒／241 采样通过；构建 7 仅 35 次／约1050秒，未完成。构建 9、10 尚无完整两小时报告。

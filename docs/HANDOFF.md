# Flowmori 交接（2026-10-20，直接交互与截图标注候选）

## 当前状态

项目 `/Users/baiyu/Documents/macflow`，本机 Swift/AppKit/SwiftUI 应用，固定安装 `/Users/baiyu/Applications/Flowmori.app`。按 `docs/OPENCODE-IMPLEMENTATION-PLAN.md` 执行，禁止用替代交互冒充真实菜单栏操作。

- 已建立本地 Git：分支 `main`，基线提交 `9ff965d8b4a2a8f6175440453b8c7f7288c6eb43`，提交信息“当前实现基线：旧菜单临时拖出归位路径（待替换）”。后续直接交互、QA 探针与截图标注改动尚未提交。
- 已安装 repair7 是旧归位路径，SHA256 `a3cec317fe3bfa63e02a1ca39385da80a4b131ff5a4ef6a8a744e234e5b3fe1d`；旧归位验收曾两轮通过，但已被新交互取代，不得当作新体验通过。
- 新源码尚未构建/安装；安装新候选会改变 ad-hoc 签名并重置辅助功能与屏幕录制授权，需用户重新勾选。
- 用户要求：收纳盒内点击直接触发原菜单/弹窗；允许真实菜单栏图标拖入；截图选区立即标注（矩形、箭头、文字、画笔、删除、撤销/重做）；仅本地 Git。

## 已确认的交互矩阵

- Normal 收起状态 `AXPress`：返回 `-25204`，但真实菜单出现在屏幕内（X=6, Y=34, 146×69），图标未移动。证据 `.validation/build10-direct-probe2-normal.json`。
- Popover 收起状态 `AXPress`：返回 `0`，真实弹窗出现在屏幕内（X=0, Y=28, 286×176），图标未移动。证据 `.validation/build10-direct-probe2-popover.json`。
- Right：仅暴露 `AXPress`，触发的是左侧普通菜单；`AXShowMenu` 返回 `-25206`。右键直开不可行，产品必须提示“展开菜单栏”后手动操作。证据 `.validation/build10-direct-probe-right.json`、`...-right-showmenu.json`。
- 真实菜单栏图标拖入：普通拖拽无效果；Command 拖拽只会把状态项移到 `[567,595]` 并脱离菜单栏，drop 窗口没有 `drag-entered`，无法取得来源。当前不可实现。证据 `.validation/build10-drag-native-left.json`、`.validation/build10-drag-native-command.json`。
- 旧夹具在 Command 拖拽后堆叠损坏，已改用新身份 `app.flowmori.MenuBarFixture2`、autosave `Flowmori.QA.2.*`、日志 `/tmp/flowmori-qa-events.jsonl`。当前恢复顺序 Normal/Popover/Right = 695/905/1032；旧 ID/PID 已失效。

## 已实现的候选代码

- 直接激活：`MenuAccessibilityCatalog` 重扫 `AXExtrasMenuBar`，按 label/最近 frame 匹配，`MenuBarEntry.supportedActions` 分流左键/右键能力；`MenuBarManager.activate` 不再移动图标，记录前后 owner/host 可见窗口，真实出现菜单/弹窗后才等待关闭；失败只提示，不自动展开。
- 收纳面板：点击图标直接打开；右键项按 `rightDirectAvailable` 禁用；新增明确“展开菜单栏”按钮，仅作为不可直接操作时的出口。
- 截图标注：新增 `AnnotationEditorController`、`AnnotationCanvasView`、`AnnotationModel`。截图回调改为原图进入编辑器，不再立即复制。支持矩形、箭头、文字、画笔、选择/移动/删除、矩形与箭头控制点、文字重编辑、撤销/重做；完成复制、保存、贴图、取消；导出按原像素尺寸，不含工具栏/选择框/控制点。`CaptureService` 完成选区后不再抢先恢复焦点，由编辑器关闭时恢复。
- 自动测试：`bash scripts/swift-command.sh test` 当前 **54 项／9 组通过**，含 5 项标注几何/导出测试；完整输出 `.validation/build10-final-unit-tests.log`。
- 可行性探针：`.validation/build10-direct-probe2-*.json`、`.validation/build10-drag-native-*.json`；QA 新增 `probeDirect`、`dragNative`、`sampleLayout`、拖放接收探针。

## 尚未完成／风险

1. 新候选尚未 release 构建、安装和真实 UI 验收；TCC 尚未为新签名授权。
2. `scripts/qa/menu-acceptance.py` 已改为直接激活断言：Normal/Popover 必须真实打开且高频采样无图标移动；Right 明确标记不可支持，验证“展开菜单栏”出口。脚本尚未在新候选上运行。
3. 截图编辑器尚未做真实中文输入法、文本换行、保存/贴图/剪贴板一致性、取消不改剪贴板、Retina 像素尺寸的端到端验收；目前只有几何/导出单测。
4. 真实拖入不可行，需用户接受“暂不实现”；右键直开需接受“展开菜单栏”出口。不能自行改成面板内拖动。
5. 新交互后的源应用退出、权限撤销、睡眠恢复、两小时监测均未完成。
6. `scripts/qa/README.md`、`docs/VALIDATION.md`、`docs/UI-TEST-PLAN.md` 已同步本轮方案，但验收结果仍需在安装后追加。

## 下一步

1. 复核源码与文档，提交本地 Git。
2. 统一 `bash scripts/build-app.sh release`，复制已签名 dist 到固定路径；请用户重新授权辅助功能+屏幕录制。
3. 先运行 `menu-acceptance.py`：Normal/Popover 通过，Right 记录 unsupported；再验证截图编辑器完整流程。
4. 修正真实 UI 问题后集中重构建；最后更新 VALIDATION、提交、打包。

## 工具与命令

- 菜单测试：`bash scripts/swift-command.sh test --filter 'MenuWindowResolverTests|MenuCollectionTests|MenuLayoutStabilityTests|MenuNotchReturnTests'`
- 全部测试：`bash scripts/swift-command.sh test`
- 构建/安装：`bash scripts/build-app.sh release`；`ditto dist/Flowmori.app /Users/baiyu/Applications/Flowmori.app`
- QA：`bash scripts/qa/build.sh`；`python3 scripts/qa/run.py '{"op":"probeDirect",...}'`；`python3 scripts/qa/menu-acceptance.py --output .validation/...`
- 心脏诊断：`.validation/heartbeat-*.json`；QA 事件 `/tmp/flowmori-qa-events.jsonl`
- 禁止修改 TCC 数据库、点击其他应用业务菜单、未核对 PID 发信号；锁屏停止输入。

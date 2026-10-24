# 本机界面验收工具

这些工具仅用于手动发起的本机验收，不进入 Flowmori.app，也不注册登录启动。执行前需允许脚本宿主使用辅助功能；宿主权限与产品权限独立。测试范围见 [测试说明](../../docs/TESTING.md)。

## 构建与启动

```sh
bash scripts/qa/build.sh
open '.validation/Flowmori QA.app' --args --fixture /tmp/flowmori-qa-events.jsonl
python3 scripts/qa/run.py '{"op":"status"}'
python3 scripts/qa/run.py '{"op":"tree","bundle":"ai.flowmori.Flowmori"}'
```

夹具标识为 `app.flowmori.MenuBarFixture2`，提供专用文档和 Normal / Popover / Right 三个状态项。包外 `FlowmoriQAHelper` 执行短命令，避免被系统误判为夹具退出。

## 菜单回归

先安装并授权产品，确保夹具已启动：

```sh
python3 scripts/qa/menu-acceptance.py --output .validation/menu-acceptance.json
```

验证真实菜单动作、弹窗关闭、面板关闭，以及状态图标无移动并在结束后保持收起。右键不支持 `AXShowMenu` 时允许回退 `AXPress`，但不计为右键专用菜单验证。

夹具事件默认写入 `/tmp/flowmori-qa-events.jsonl`；若启动时使用其他日志路径，需给脚本设置相同的 `FLOWMORI_QA_EVENTS`。

## 恢复回归

产品需以 `--diagnostics` 参数启动，参见 [连续运行检查](../../docs/TESTING.md#连续运行检查)。

```sh
python3 scripts/qa/menu-recovery.py --case exit \
  --heartbeat .validation/heartbeat.json --output .validation/recovery-exit.json
```

源退出预期为 `sourceTerminated`、菜单栏保持收起且夹具图标清除。此检查会退出专用夹具。

超时检查先退出已有夹具，再以保持弹窗模式启动，避免外部点击提前关闭弹窗：

```sh
open '.validation/Flowmori QA.app' --args --fixture /tmp/flowmori-qa-events.jsonl --persistent-popover
python3 scripts/qa/menu-recovery.py --case timeout \
  --heartbeat .validation/heartbeat.json --output .validation/recovery-timeout.json
```

预期两分钟后 `timedOut`、解除操作状态、展开菜单栏并显示提示。结束后需要重新收纳。`--persistent-popover` 仅改变夹具，默认弹窗仍使用 transient 行为。

## 单步探针

```sh
python3 scripts/qa/run.py '{"op":"extras","bundle":"app.flowmori.MenuBarFixture2"}'
python3 scripts/qa/run.py '{"op":"menuProbe"}'
python3 scripts/qa/run.py '{"op":"sampleLayout","duration":6,"intervalMs":50}'
python3 scripts/qa/run.py '{"op":"probeDirect","bundle":"app.flowmori.MenuBarFixture2","role":"AXMenuBarItem","text":"Flowmori QA Normal"}'
```

`press` / `set` 路径须来自刚读取的 `tree`；点击、拖动、双击坐标须来自当前测试控件的位置。只对 Flowmori 与专用夹具执行输入；图标移动探针仅允许移动夹具。锁屏立即停止，不自动解锁，不操作其他应用业务菜单，不修改 TCC 数据库。

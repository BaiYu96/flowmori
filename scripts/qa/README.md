# 本机验收辅助程序

仅在用户明确允许本地辅助功能／系统事件脚本后使用，范围见 `docs/UI-TEST-PLAN.md`。这些文件不会进入 Flowmori.app，也不会注册登录启动。

`bash scripts/qa/build.sh` 生成 `.validation/Flowmori QA.app` 和包外 `.validation/FlowmoriQAHelper`。夹具身份为 `app.flowmori.MenuBarFixture2`，autosave 为 `Flowmori.QA.2.*`，事件日志写在 `/tmp/flowmori-qa-events.jsonl`，不要再用旧夹具 ID `app.flowmori.MenuBarFixture` 或 `.validation/build7-fixture-events.jsonl`。

```sh
bash scripts/qa/build.sh
open '.validation/Flowmori QA.app'
python3 scripts/qa/run.py '{"op":"status"}'
python3 scripts/qa/run.py '{"op":"tree","bundle":"app.flowmori.Flowmori"}'
python3 scripts/qa/run.py '{"op":"extras","bundle":"app.flowmori.MenuBarFixture2"}'
python3 scripts/qa/run.py '{"op":"menuProbe"}'
```

## 菜单探针

`menuProbe`、`menuDrag`、`menuMoveBefore`、`menuClick` 编译并调用当前产品的菜单栏兼容层。只有本测试程序的图标允许被移动或点击。

`probeDirect` 只对夹具使用：重新解析 `AXExtrasMenuBar`，可指定 `AXPress` 或 `AXShowMenu`，并在动作前后采样布局、AX 菜单/弹窗状态和 `CGWindowList` 窗口 frame：

```sh
python3 scripts/qa/run.py '{"op":"probeDirect","bundle":"app.flowmori.MenuBarFixture2","role":"AXMenuBarItem","text":"Flowmori QA Normal"}'
```

`dragNative` 用产品式 CGEvent 拖拽夹具图标到指定坐标，可选 `command:true`。`--drag-probe` 模式会打开拖放接收窗口，记录 `drag-entered` 等事件。当前结果：普通拖拽无效果；Command 拖拽只移动并脱离状态项，没有拖放会话，因此真实“拖入收纳盒”不可实现。

`sampleLayout` 在指定时长内以约 50ms 间隔采样允许应用的图标 frame，输出 `changeCount`/`changes`，用于证明直接激活期间没有临时移出：

```sh
python3 scripts/qa/run.py '{"op":"sampleLayout","duration":6,"intervalMs":50}'
```

## 直接激活验收

先确保新候选已安装并授权。`python3 scripts/qa/menu-acceptance.py` 只点击 Flowmori 与夹具控件：

- Normal/Popover：打开收纳面板，点击代理图标，确认真实菜单/弹窗出现并执行动作；后台 `sampleLayout` 必须报告 0 次图标移动，结束后连续至少 4 秒保持收起且顺序为 Normal/Popover/Right。
- Right：夹具只暴露 `AXPress`，右键直开被产品禁用；脚本记录 `unsupportedReason`，并验证“展开菜单栏”出口能真实展开，再收纳回原位。不能把 Right 写成通过。

证据默认写入 `.validation/menu-panel-acceptance.json`，可用 `--output` 指定。若脚本报 Right 直开突然可用，必须重新设计完整右键验收，不能删除断言。

## 其他

`key` 仅在 Flowmori 或夹具前台时工作。`press`、`set` 的路径来自上一次 `tree` 输出。坐标点击/拖动必须依据刚读取的测试控件或图标位置。执行鼠标操作前检查屏幕布局是否变化；锁屏立即停止输入。

辅助功能授权归属于执行脚本的宿主（本机显示为 ChatGPT.app），与 Flowmori 自身授权不同。脚本不读取或修改 TCC 数据库。命令行请求通过包外 `FlowmoriQAHelper` 执行，避免系统把探测退出误报为夹具退出。

旧 `menu-recovery.py` 的超时/源退出断言仍以旧“必须展开”语义为背景；直接交互版本需按新方案更新后再运行，不能直接沿用作为通过证据。恢复验收的其他限制见 `docs/VALIDATION.md`。

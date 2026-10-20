# 本机验收辅助程序

仅在用户明确允许本地辅助功能／系统事件脚本后使用，范围见 `docs/UI-TEST-PLAN.md`。这些文件不会进入 Flowmori.app，也不会注册登录启动。

`bash scripts/qa/build.sh` 生成 `.validation/Flowmori QA.app`。它提供三个菜单栏图标（普通菜单、弹窗、右键）和一个包含固定内容的专用测试文档。事件记录使用启动参数指定的 JSONL 文件：

```sh
open '.validation/Flowmori QA.app' --args --fixture "$PWD/.validation/menu-fixture-events.jsonl"
python3 scripts/qa/run.py '{"op":"status"}'
python3 scripts/qa/run.py '{"op":"tree","bundle":"app.flowmori.Flowmori"}'
python3 scripts/qa/run.py '{"op":"extras"}'
python3 scripts/qa/run.py '{"op":"menuProbe"}'
```

`menuProbe`、`menuDrag`、`menuMoveBefore`、`menuClick` 编译并调用当前产品的菜单栏兼容层，而不是另写一份模拟实现。只有本测试程序的图标允许被移动或点击；`menuMoveBefore` 的相邻项也必须属于 Flowmori 或本测试程序。

`key` 仅在 Flowmori 或测试程序前台时工作，使用真实系统事件路径。`press`、`set` 的路径来自上一次 `tree` 输出，只允许这两个应用。坐标点击和拖动必须依据刚读取的指定测试窗口／图标位置，不得将脚本用于其他业务应用。执行鼠标操作前检查屏幕布局是否变化。

辅助功能授权归属于执行脚本的宿主（此验收环境显示为 ChatGPT.app），与 Flowmori 和电脑控制工具各自的授权不同。脚本不读取或修改系统权限数据库。

命令行请求通过 App 包外的 `FlowmoriQAHelper` 执行，避免系统把每次探测的退出误报为测试应用退出，干扰正在验证的生命周期恢复。锁屏时拒绝发送输入；快捷键前再次核对专用测试应用焦点。

完整收纳面板回归：将三个测试图标放在分隔符左侧并关闭面板后，执行 `python3 scripts/qa/menu-acceptance.py`。脚本仅点击 Flowmori 和专用测试图标的控件，验证普通菜单、弹窗、右键和原始顺序恢复；失败即停止，并将证据写入 `.validation/menu-panel-acceptance.json`，可用 `--output` 指定其他证据文件。

面板回归通过产品菜单栏入口打开，排除设置窗口的同名按钮，归位后至少连续四秒保持收起才计通过。Option+M 的快捷键验收应独立进行。

恢复验收要求构建 6 或更新版本已授权，使用 `--diagnostics` 启动，并预先把三个测试图标放入收纳区：

```sh
python3 scripts/qa/menu-recovery.py --case timeout \
  --heartbeat .validation/heartbeat-flowmori-build6.json \
  --output .validation/build6-timeout-proof.json
python3 scripts/qa/menu-recovery.py --case exit \
  --heartbeat .validation/heartbeat-flowmori-build6.json \
  --output .validation/build6-source-exit-proof.json
```

超时检查让专用弹窗保持打开约两分钟；期间关闭弹窗、锁屏或应用变化可能使操作取消，取消不能替代超时通过。退出检查只正常退出已核对身份的测试应用 PID。两项都核对同一产品进程、心跳时效、具体结束分支、展开状态和中文说明。退出检查后需要重新启动测试应用并准备收纳区。此脚本不撤销系统权限，也不注销用户会话。

# 测试与验证

## 自动测试

在 Apple Silicon Mac、macOS 26 和 Swift 6 工具链下运行：

```sh
bash scripts/swift-command.sh test
```

测试使用隔离的偏好设置、临时存储和命名剪贴板，覆盖历史存储、迁移、过滤、坐标换算、截图标注、菜单快照校验和快捷键。部分平台测试需要访问 macOS 剪贴板及快捷键服务，在受限沙箱中可能失败。

## 构建检查

```sh
bash scripts/build-app.sh release
codesign --verify --strict dist/Flowmori.app
dist/Flowmori.app/Contents/MacOS/Flowmori --diagnose
```

`--diagnose` 只作辅助诊断。权限也应在应用设置页检查，并以真实截图和菜单操作确认。重建 ad-hoc 签名后，系统可能要求重新授权。

## 界面回归

使用测试内容和专用夹具，避免操作其他应用的业务菜单。锁屏时停止输入；不修改 TCC 数据库。

| 模块 | 检查内容 |
| --- | --- |
| 历史 | 文本、富文本、图片、中文搜索、收藏、删除、容量限制、暂停及排除应用 |
| 截图 | 各方向框选、移动/缩放选框、矩形/直线/箭头/文字/画笔、颜色与线宽、编辑、撤销/重做 |
| 输出 | 保存、复制、贴图的尺寸与像素一致；不含工具栏；取消不改剪贴板 |
| 贴图 | 拖动、缩放、复制、保存、隐藏/恢复、关闭 |
| 菜单栏 | 普通菜单、子菜单、右键回退、弹窗、自动收纳、源应用退出、超时恢复 |
| 设置 | 快捷键冲突、登录启动、权限入口、版本与图标 |
| 系统变化 | 睡眠唤醒、权限撤销、登录、显示器/缩放变化 |

菜单夹具和恢复脚本使用方法见 [QA 工具说明](../scripts/qa/README.md)。单元测试不能替代权限、系统菜单及多显示器的实机验证。

## 连续运行检查

先退出已经运行的实例，再启动待测应用：

```sh
mkdir -p .validation
open dist/Flowmori.app --args --diagnostics "$PWD/.validation/heartbeat.json"
python3 scripts/soak.py \
  --heartbeat "$PWD/.validation/heartbeat.json" \
  --output "$PWD/.validation/soak" --seconds 7200
```

检查同一进程的主循环、剪贴板轮询、CPU 与内存。工具不会读取剪贴板正文；结果写入 `samples.jsonl` 和 `report.json`。短时检查不代表两小时检查通过，连续运行通过也不代表全部界面功能通过。

日志、截图、心跳、构建产物和本机开发笔记均保留本地，不提交 Git，也不进入源码发布包。

## 0.1.49 新增回归项目

以下界面场景仍需实机验证，构建成功不代表已通过。

- 截图中按 Option+P，确认贴图位置、尺寸、标注正确并退出截图，覆盖 Retina 和多屏。
- 马赛克涂抹、撤销、导出与钉图，确认没有虚线选框。
- V/R/L/A/T/B/M 切换工具，输入中文或英文标注时不误触工具切换。
- 贴图滚轮与捏合缩放、双击恢复初始大小、Option+滚轮透明度及右键操作。
- 连续 Option+P 依次输出当前剪贴板和历史，覆盖混合文字图片、新复制重置和历史耗尽。
- 文字贴图的中文、换行、长行、空白和超长文字处理。
- 合盖锁屏再唤醒后收纳状态，以及 Flowmori 图标被刘海遮挡时启动收纳。

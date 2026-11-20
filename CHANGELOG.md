# Changelog / 更新日志

## 0.1.50 — 2026-11-20

- Improved collection in crowded menu bars and near the notch by arranging manageable icons before positioning the collection controls.
- 优化图标较多及刘海附近的收纳排序，先整理可管理图标，再定位收纳控制项。
- Route native clicks to the status-window host with its window ID; read standard menus dynamically and execute selections in the source app. Preserve left/right click identity in menu caching and execution.
- 原生点击携带窗口 ID 并发往状态图标宿主；实时读取标准菜单并在源应用执行菜单项，缓存和执行保留左右键区别，改善向日葵等应用的菜单访问。
- Bring newly opened off-screen native popovers into the visible display without moving the collected icon, including supported WPS popovers.
- 将新打开在屏幕外、支持窗口定位的原生弹窗移到可见区域，改善 WPS 弹窗显示，收纳图标保持原位。
- Lower the collection panel below native popovers and keep it open while interacting with them.
- 降低收纳盒面板层级，避免遮挡原生弹窗；弹窗打开、操作及关闭时不再主动关闭收纳盒。
- App version 0.1.50, build 50. / 应用版本 0.1.50，构建号 50。

## 0.1.49 — 2026-11-08

- Added mosaic brushing without a dashed selection outline and V/R/L/A/T/B/M screenshot tool shortcuts.
- 新增马赛克涂笔，隐藏其虚线选框；新增 V/R/L/A/T/B/M 截图工具快捷键。
- Option+P pins the selected screenshot at its original position and size, including annotations.
- 截图中按 Option+P 直接钉图并退出，保留选区位置、尺寸和标注。
- Repeated Option+P presses outside capture pin current clipboard contents, then history from newest to oldest. Text is rendered as a wrapped white card.
- 截图界面外连续按 Option+P，依次钉出当前剪贴板内容与从新到旧的历史；文字自动换行并生成白底贴图。
- Added pin opacity adjustment with Option-scroll, double-click size reset, and context-menu size and opacity controls.
- 新增 Option+滚轮调整贴图透明度、双击恢复初始大小，以及右键缩放与透明度选项。
- Display-parameter notifications no longer immediately expand collection. Collection startup recovers its own hidden status items before resolving layout.
- 显示器参数变化后等待布局稳定再检查收纳；启动收纳前先恢复被刘海遮挡的自身状态项。
- App version 0.1.49, build 49. / 应用版本 0.1.49，构建号 49。

## 0.1.48 — 2026-11-02

- Added a straight-line tool to screenshot annotations, with color and width controls, endpoint editing, moving, undo/redo, and export.
- 截图标注新增「直线」工具，支持颜色与粗细调整、端点编辑、移动、撤销与重做，并保留在导出图片中。
- App version: 0.1.48; build: 48. / 应用版本：0.1.48；构建号：48。

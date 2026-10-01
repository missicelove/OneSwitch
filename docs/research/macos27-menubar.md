# macOS 27 菜单栏机制调研（2026-09-29 晚）

## 现象（用户反馈）
- Mac Studio：收起时左侧出现系统的「«」，中间一大片空白，右侧是 OneSwitch 的「<」。
  点「«」→ 隐藏图标覆盖在 App 菜单区显示；点「<」→ 图标在竖线左侧展开，但动画像是“从别处飞进来”。
- MacBook Pro（刘海屏、图标很多）：只有「«」，看不到 OneSwitch 的「<」；无法把图标拖到分隔线左侧。
- 用户期望：只保留 OneSwitch 的「<」，点击后隐藏图标在竖线左侧展开，没有「«」。

## 调研结论
1. **macOS 27 由新的系统进程 MenuBarAgent 统一排布菜单栏**（/System/Library/CoreServices/MenuBarAgent.app），
   App 的状态栏图标变成了 `NSSceneStatusItem`（场景式），整条菜单栏是一个窗口。
2. **溢出是按“单个图标”进行的**：实验中把一个图标设成 3000pt 宽，只有它自己被丢弃，
   它左边的图标照常显示、也没有出现「«」。Hidden Bar 式“一条长分隔线把左边全部挤出屏幕”的老办法
   在 macOS 27 上失效。
3. OneSwitch 现在的做法是把分隔线设成“刚好填满剩余空间”，让它左边的图标放不下而进入系统溢出区，
   因此必然出现「«」；那片“空白”就是分隔线本身（其实就是菜单栏原本的空闲区域）。
4. MenuBarAgent 内部的布局属性：每个图标有 `priority`、`dropPriority`、`allowsOverflow`、
   `preferredDistanceFromTrailingMenuBarEdge`；全局有 `minimumItemsForOverflow`
   （≥2 个图标溢出时才显示「«」）。这些都**不是公开设置**，第三方 App 无法关闭「«」。
5. `NSStatusItem` 在 macOS 27 的私有接口：`_setOverflowSpecifierPriority:`、
   `_statusItemWithLength:withPriority:` 对场景式图标**无效**（读回始终是默认值）；
   `_dragStatusItemWithOffset:`、`_sendSavedPreferredPosition` 存在，可能可用。
6. **首选位置 = 距屏幕右边缘的点数**，保存在各 App 自己的偏好里：
   `"NSStatusItem Preferred Position <autosaveName>"`。例（MBP）：控制中心 143、Wi‑Fi 185、电池 223、
   输入法 265、聚焦 347、微信 598、Deskflow 611、飞书 613、Syncthing 649。
   OneSwitch 可以在创建图标前写入自己的首选位置，把切换按钮固定在右侧系统图标旁边
   → 菜单栏再挤也是左边的第三方图标先被收进「«」，OneSwitch 的按钮不会被收走（解决 MBP 问题）。

## 可选方案（待与用户确认）
- **A. 与系统溢出配合（推荐）**：切换按钮固定在右侧；收起时隐藏图标进入系统「«」；点 OneSwitch 的「<」
  展开 5–60 秒后自动收起；支持快捷键。缺点：收起时仍会看到系统的「«」（macOS 27 无法去掉）。
- **B. 只用系统「«」**：OneSwitch 不再显示自己的按钮，只负责决定哪些图标进「«」和“展开 N 秒后自动收起”。
  菜单栏最干净，但开关是系统的「«」而不是「<」。
- **C. 系统设置 → 菜单栏 → “允许在菜单栏显示”**：按 App 永久隐藏，无法临时展开。

## 待验证（需要屏幕解锁时做）
- 写入 `Preferred Position` 后，切换按钮是否确实出现在右侧（Studio 和 MBP 各一次）。
- 展开/收起时能否减少“飞入”动画（一次性设置宽度 vs 分步）。
- 用户能否直接把图标 ⌘-拖进系统「«」来隐藏。

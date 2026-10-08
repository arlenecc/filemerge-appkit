# 文件去重合并工具（FileMerge）

一个运行于 macOS 的图形化工具，用于把**主目录**与**副目录**中分散、可能重复的文件去重后合并进一个**最终目录**。核心逻辑为纯 Objective-C 库，界面由 AppKit 构建，使用 Swift Package Manager 管理。

- 应用名：`文件去重合并工具`
- 最低系统版本：macOS 13.0
- 语言/框架：Objective-C（Foundation + AppKit）、SwiftPM 5.9
- 第三方依赖：无

---

## 目录

- [功能特性](#功能特性)
- [工作原理](#工作原理)
- [界面与交互](#界面与交互)
- [项目结构](#项目结构)
- [核心模块说明](#核心模块说明)
- [构建与运行](#构建与运行)
- [测试](#测试)
- [错误码](#错误码)
- [设计要点](#设计要点)

---

## 功能特性

- **全局去重合并**：在主、副两目录的全部子目录之间按文件内容做唯一性判定，同名同内容只保留一份。
- **三级去重**（`FMDedupEngine`）：
  1. 尺寸唯一 → 免哈希直接判为唯一；
  2. 前 64KB 头部 SHA256 预筛；
  3. 全量分块（256KB）SHA256 兜底。
- **主目录优先**：主/副同内容时保留主目录条目；同源内部重复按相对路径 Unicode 升序保留第一个。
- **哈希缓存**：同一运行内同一文件不重复计算（跨运行不持久化）。
- **安全校验**（`FMMergeValidator`）：通过 `realpath` 解析最长存在祖先，拒绝主/副/终目录相同、互为祖先后代、符号链接别名、大小写折叠别名等自我覆盖风险。
- **可预测的合并策略**（`FMMergeEngine` 两步走）：
  - 先**串行构建计划**（不写盘）：对每个文件决策为 写入 / 覆盖 / 跳过 / 重命名 / 拒绝；
  - 再**有界并发执行**复制（worker 约束到 `[2, 16]`，默认 `min(max(4, 核数), 16)`）。
- **幂等合并**：目标已存在且内容相同则跳过；重复运行不会产生冗余副本。
- **冲突重命名**：副目录文件与已写入文件冲突且内容不同时，生成 `名称 (n).ext` 候选。
- **原子覆盖**：覆盖时先复制到临时文件再 `replaceItemAtURL:` 原子替换，避免中途失败丢失旧文件。
- **可取消**：引擎在文件粒度轮询取消标志，当前文件处理完成后尽快回到空闲。
- **实时进度与日志**：线程安全的进度上报（单调钳制、默认 100ms 节流）；终端风格日志（时间戳、自动滚动、上限裁剪）。
- **记住上次目录**：通过 `NSUserDefaults` 持久化最近选择的三条路径。

---

## 工作原理

整体流程（由 `FMAppViewModel` 状态机驱动）：

```
[空闲 Idle]
   │  选择 主目录 / 副目录 / 最终目录 → 点击「开始分析」
   ▼
[分析中 Analyzing]
   1. FMMergeValidator  安全校验（路径冲突/别名）
   2. FMFileScanner      并行扫描主、副目录（0–20%）
   3. FMDedupEngine      全局哈希排重（20%–100%）
   4. FMAnalysisResult   汇总统计 + 预估合并后体量
   ▼
[已分析 Analyzed]  展示主/副/预估统计，可开始合并
   │  点击「开始合并」
   ▼
[合并中 Merging]
   1. FMMergeValidator  合并前复检（防分析后外部环境变化）
   2. FMMergeEngine      buildPlan（串行决策）
   3. FMMergeEngine      executePlan（有界并发写盘）
   ▼
[空闲 Idle]  合并完成，回写统计
```

> 说明：分析阶段产生的 `FMFileHasher` 会被合并阶段复用，计划期的「目标已存在内容比较」直接命中排重时的哈希缓存，避免对已读文件重新全量读取。

---

## 界面与交互

主窗口（`FMMainViewController`，手动 Auto Layout，配置区 : 显示区 ≈ 1 : 2）：

- **上 1/3 配置区**
  - 主目录 / 副目录 / 合并目录 三个路径输入框 + 「浏览…」按钮（以窗口 sheet 形式弹出目录选择器）。
  - 「开始分析」按钮：空闲或已分析且三路径均非空时可用。
- **下 2/3 显示区**
  - 顶部统计条：主目录统计、副目录统计、预计合并后统计（文件数 + 可读字节数）。
  - 「开始合并」按钮（回车键触发）：仅「已分析」状态可用。
  - 中部日志区：深色底白字的滚动日志，自动滚到最新（仅当用户已在底部时）。
  - 底部状态栏：进度条 + `百分比 · 阶段描述` + 「取消」按钮（仅分析中/合并中可用）。

状态机（`FMAppState`）：`Idle → Analyzing → Analyzed → Merging → Idle`。已分析状态下更换任一目录会使原结果失效并回到空闲。

---

## 项目结构

```
merge/
├── Package.swift              # SwiftPM 清单（4 个 target）
├── scripts/
│   ├── make_app.sh            # 打包 build/FileMerge.app
│   ├── test.sh                # 运行测试（含 swift-testing 插件修复）
│   ├── Info.plist             # 应用包信息（中文、图标、最低版本）
│   └── AppIcon.icns           # 应用图标
├── Sources/
│   ├── FileMergeCore/         # 纯 ObjC 核心库（扫描/哈希/排重/合并/校验/进度）
│   │   ├── include/*.h
│   │   ├── FMFileScanner.m
│   │   ├── FMFileHasher.m
│   │   ├── FMDedupEngine.m
│   │   ├── FMMergeEngine.m
│   │   ├── FMMergeValidator.m
│   │   ├── FMProgressReporter.m
│   │   ├── FMModels.m
│   │   └── FMError.m
│   ├── FileMergeUI/           # AppKit 图形界面
│   │   ├── include/*.h
│   │   ├── FMAppViewModel.m   # 界面状态机（可单元测试）
│   │   └── FMMainViewController.m
│   └── FileMergeApp/          # 可执行入口
│       └── main.m             # AppDelegate + 主菜单 + 入口
└── Tests/
    ├── FileMergeCoreTests/    # Swift（swift-testing）驱动 ObjC 生产代码
    └── FileMergeUITests/      # （占位，暂无用例）
```

### 模块依赖

```
FileMergeApp ──▶ FileMergeUI ──▶ FileMergeCore
```

---

## 核心模块说明

| 模块 | 职责 |
|------|------|
| `FMFileScanner` | 并行深扫目录，收集普通文件（忽略符号链接）；根目录不可读返回错误而非静默空结果；子目录不可读记入 warnings。 |
| `FMFileHasher` | 提供 `headHashForFile:`（前 64KB，文件不足则全量）与 `fullHashForFile:`（256KB 分块流式）；结果按路径缓存，并暴露计算次数供缓存命中测试。 |
| `FMDedupEngine` | 全局统一排重，三级去重 + 主目录优先 + 同源 Unicode 升序；以哈希工作量为进度单元分阶段 `expandTotalBy:`。 |
| `FMMergeEngine` | 先 `buildPlanPrimary:secondary:finalRoot:` 串行决策（写入/覆盖/跳过/重命名/拒绝），再 `executePlan:progress:` 有界并发写盘；覆盖走原子替换。 |
| `FMMergeValidator` | 合并前路径安全校验：`resolvePath` 经 `realpath` 解析最长存在祖先，拒绝三目录相同/互为祖先/大小写别名。 |
| `FMProgressReporter` | 线程安全进度上报：总量只增不减、fraction 单调钳制、回调节流（默认 100ms）、`finish` 收敛到 100%。 |
| `FMModels` | 数据模型：`FMFileRecord`、`FMAnalysisStats`、`FMAnalysisResult`、`FMDedupResult`、`FMMergePlanItem`、`FMMergeOutcome`。 |
| `FMError` | 统一错误域 `FMErrorDomain` 与错误码。 |

### 合并计划动作（`FMPlanAction`）

| 动作 | 触发条件 |
|------|----------|
| `Copy` | 目标不存在 → 新写入 |
| `Overwrite` | 目标同名但内容不同（主目录文件）→ 原子覆盖 |
| `Skip` | 目标已存在且内容相同 → 幂等跳过 |
| `Rename` | 目标冲突且内容不同（副目录）→ `名称 (n).ext` |
| `Error` | 拒绝执行（如覆盖目标为目录、无法生成重命名路径） |

---

## 构建与运行

### 前置条件

- macOS 13.0+
- Swift 工具链（Xcode Command Line Tools 或 Xcode，`swift` 可用）

### 构建可执行文件

```bash
swift build -c release --product FileMergeApp
# 产物：.build/release/FileMergeApp
```

### 打包为 .app

```bash
./scripts/make_app.sh
# 生成 build/FileMerge.app（含 Info.plist、AppIcon，自动 ad-hoc 签名）
open build/FileMerge.app
```

---

## 测试

核心逻辑由 Swift 编写的 `swift-testing` 用例驱动 Objective-C 生产代码，覆盖扫描、哈希、排重、合并引擎、校验器与进度器。

```bash
./scripts/test.sh
```

> 注：`test.sh` 内部对 `swift test` 追加了 `-Xswiftc -Xfrontend -Xswiftc -load-resolved-plugin` 等参数，以修复本机 Command Line Tools 下 `swift-testing` 宏插件（`TestingMacros`）加载失败的问题，并加 `--disable-sandbox` 允许插件 `dlopen`。若 `/tmp/fm2/swift/host` 镜像被系统清理，需按脚本注释重建语法库镜像。

测试用例位于 `Tests/FileMergeCoreTests/`：

- `FileScannerTests.swift`、`HasherTests.swift`、`DedupEngineTests.swift`
- `MergeEngineTests.swift`、`MergeValidatorTests.swift`、`ProgressReporterTests.swift`
- `AppViewModelTests.swift`（状态机）、`FMSupport.swift`（测试支撑）

---

## 错误码

| 码 | 含义 |
|----|------|
| `FMErrorCancelled` (1) | 操作被用户取消 |
| `FMErrorRootUnreadable` (2) | 根目录不可读（避免静默空合并） |
| `FMErrorInvalidRoot` (3) | 根目录不存在或不是目录 |
| `FMErrorValidationFailed` (4) | 安全校验未通过（路径冲突/别名等） |
| `FMErrorTargetIsDirectory` (5) | 覆盖目标为目录，拒绝执行 |
| `FMErrorHashFailed` (6) | 哈希计算失败 |
| `FMErrorCopyFailed` (7) | 复制失败 |

---

## 设计要点

- **排重正确性**：并发哈希结果插入顺序不确定，决策前按 `主目录优先 + 相对路径 Unicode 升序` 重新排序，保证可复现、可单测。
- **进度单调**：扫描段固定占 0–20%，排重段映射 20%–100%，总量扩展导致的回落被进度器钳制，避免进度条回跳。
- **失败可见**：哈希失败、复制失败、目录拒绝等均记入日志/错误列表，不会静默丢文件；去重告警封顶 50 条并附汇总行。
- **自我防护**：覆盖前判定目标是否为目录，防止 `replaceItemAtURL:` 把目录整棵子树替换成文件；合并前复校路径，防御分析后符号链接等外部环境变化。
- **视图模型可测**：`FMAppViewModel` 不含界面代码，通过 `delegate` + 可注入 `callbackQueue` 驱动 UI，便于单元测试。

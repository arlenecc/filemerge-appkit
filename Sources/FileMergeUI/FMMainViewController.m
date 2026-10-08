#import "FMMainViewController.h"
#import "FMAppViewModel.h"
#import "FMModels.h"

#pragma mark - 常量与文件级工具

static const CGFloat FMRowHeight = 24.0;

static NSString *FMHumanBytes(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes;
    NSString *unit = @"KB";
    for (NSString *u in @[ @"KB", @"MB", @"GB", @"TB", @"PB" ]) {
        v /= 1024.0;
        unit = u;
        if (v < 1024.0) break;
    }
    return [NSString stringWithFormat:@"%.2f %@", v, unit];
}

static NSDateFormatter *FMLogFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return formatter;
}

#pragma mark - 私有扩展

@interface FMMainViewController () <FMAppViewModelDelegate>
{
    NSUInteger _logLineCount;  // 已追加日志行数（用于 2000 条上限裁剪）
}

@property (nonatomic, strong) FMAppViewModel *viewModel;

// 配置区（上 1/3）
@property (nonatomic, strong) NSTextField *primaryLabel;
@property (nonatomic, strong) NSTextField *secondaryLabel;
@property (nonatomic, strong) NSTextField *finalLabel;
@property (nonatomic, strong) NSTextField *primaryField;
@property (nonatomic, strong) NSTextField *secondaryField;
@property (nonatomic, strong) NSTextField *finalField;
@property (nonatomic, strong) NSButton *pickPrimaryButton;
@property (nonatomic, strong) NSButton *pickSecondaryButton;
@property (nonatomic, strong) NSButton *pickFinalButton;
@property (nonatomic, strong) NSButton *startAnalysisButton;
@property (nonatomic, strong) NSButton *cancelButton;

// 处理显示区（下 2/3）
@property (nonatomic, strong) NSTextField *primaryStatsLabel;
@property (nonatomic, strong) NSTextField *secondaryStatsLabel;
@property (nonatomic, strong) NSTextField *estimatedStatsLabel;
@property (nonatomic, strong) NSButton *startMergeButton;
@property (nonatomic, strong) NSScrollView *logScrollView;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *statusLabel;

@end

#pragma mark - 实现

@implementation FMMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;

    self.viewModel = [[FMAppViewModel alloc] init];
    self.viewModel.delegate = self;

    [self buildUI];

    // 恢复上次使用的目录（记住所选路径，减少重复选择）
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *p = [defaults stringForKey:@"FMPrimaryPath"];
    NSString *s = [defaults stringForKey:@"FMSecondaryPath"];
    NSString *f = [defaults stringForKey:@"FMFinalPath"];
    if (p.length > 0) { self.viewModel.primaryPath = p; self.primaryField.stringValue = p; }
    if (s.length > 0) { self.viewModel.secondaryPath = s; self.secondaryField.stringValue = s; }
    if (f.length > 0) { self.viewModel.finalPath = f; self.finalField.stringValue = f; }

    [self refreshUI];
}

#pragma mark 界面构建

- (void)buildUI {
    // ---- 配置区控件（上 1/3）----
    self.primaryField = [FMMainViewController makePathField];
    self.secondaryField = [FMMainViewController makePathField];
    self.finalField = [FMMainViewController makePathField];
    self.primaryLabel = [FMMainViewController makeRowLabel:@"主目录"];
    self.secondaryLabel = [FMMainViewController makeRowLabel:@"副目录"];
    self.finalLabel = [FMMainViewController makeRowLabel:@"合并目录"];
    self.pickPrimaryButton = [FMMainViewController makePickButtonWithTag:0 target:self];
    self.pickSecondaryButton = [FMMainViewController makePickButtonWithTag:1 target:self];
    self.pickFinalButton = [FMMainViewController makePickButtonWithTag:2 target:self];
    self.startAnalysisButton = [FMMainViewController makeButton:@"开始分析" tag:3 target:self];

    // ---- 显示区控件（下 2/3）----
    // 三个统计标签：主目录 / 副目录 / 预计合并后，纵排于操作按钮左侧
    self.primaryStatsLabel = [FMMainViewController makeStatsLabel];
    self.secondaryStatsLabel = [FMMainViewController makeStatsLabel];
    self.estimatedStatsLabel = [FMMainViewController makeStatsLabel];

    self.startMergeButton = [FMMainViewController makeButton:@"开始合并" tag:4 target:self];
    self.startMergeButton.keyEquivalent = @"\r";  // 回车触发合并

    self.logScrollView = [[NSScrollView alloc] init];
    self.logScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logScrollView.hasVerticalScroller = YES;
    self.logScrollView.borderType = NSBezelBorder;

    // 日志视图：documentView 宽度跟随滚动区，高度随内容增长（宽度必须为正值，
    // 否则文本按零宽布局导致绘制不可见）
    NSTextView *logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 60)];
    logView.editable = NO;
    logView.richText = NO;
    logView.minSize = NSMakeSize(0, 60);
    logView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    logView.verticallyResizable = YES;
    logView.horizontallyResizable = NO;
    logView.autoresizingMask = NSViewWidthSizable;
    // 固定深色底 + 白字（终端风格），浅色/深色模式下均清晰可读
    logView.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1.0];
    logView.textColor = [NSColor whiteColor];
    self.logView = logView;
    self.logScrollView.documentView = logView;

    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 1.0;
    self.progressBar.doubleValue = 0.0;
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = [NSTextField labelWithString:@"0% · 就绪"];
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelClicked:)];
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.enabled = NO;
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 挂到视图树 ----
    NSDictionary *views = @{
        @"pLbl": self.primaryLabel, @"sLbl": self.secondaryLabel, @"fLbl": self.finalLabel,
        @"pField": self.primaryField, @"pBtn": self.pickPrimaryButton,
        @"sField": self.secondaryField, @"sBtn": self.pickSecondaryButton,
        @"fField": self.finalField, @"fBtn": self.pickFinalButton,
        @"analysis": self.startAnalysisButton,
        @"pStats": self.primaryStatsLabel, @"sStats": self.secondaryStatsLabel, @"eStats": self.estimatedStatsLabel,
        @"merge": self.startMergeButton,
        @"log": self.logScrollView,
        @"bar": self.progressBar, @"status": self.statusLabel, @"cancel": self.cancelButton,
    };
    for (NSView *v in views.allValues) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }

    NSMutableArray<NSLayoutConstraint *> *c = [NSMutableArray array];

    // 三行目录选择：行内 = 标题 + 输入框 + 选择按钮（按钮统一尺寸、右对齐）
    CGFloat top = 16.0;
    CGFloat gap = 10.0;
    NSArray<NSArray *> *rows = @[
        @[ self.primaryLabel, self.primaryField, self.pickPrimaryButton ],
        @[ self.secondaryLabel, self.secondaryField, self.pickSecondaryButton ],
        @[ self.finalLabel, self.finalField, self.pickFinalButton ],
    ];
    NSLayoutYAxisAnchor *prevAnchor = self.view.topAnchor;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSTextField *label = rows[i][0];
        NSTextField *field = rows[i][1];
        NSButton *btn = rows[i][2];
        [c addObject:[field.topAnchor constraintEqualToAnchor:prevAnchor constant:(i == 0 ? top : gap)]];
        [c addObject:[label.centerYAnchor constraintEqualToAnchor:field.centerYAnchor]];
        [c addObject:[label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16]];
        [c addObject:[label.widthAnchor constraintEqualToConstant:60]];  // 三行标题等宽，输入框起始对齐
        [c addObject:[field.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:6]];
        [c addObject:[field.trailingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:-8]];
        [c addObject:[btn.centerYAnchor constraintEqualToAnchor:field.centerYAnchor]];
        [c addObject:[btn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]];
        [c addObject:[btn.widthAnchor constraintEqualToConstant:72]];    // 浏览按钮统一尺寸
        [c addObject:[field.heightAnchor constraintEqualToConstant:FMRowHeight]];
        prevAnchor = field.bottomAnchor;
    }

    // 分析按钮：与合并按钮同一行（统计条右侧、合并按钮左边），两按钮等宽
    [c addObject:[self.startAnalysisButton.centerYAnchor constraintEqualToAnchor:self.startMergeButton.centerYAnchor]];
    [c addObject:[self.startAnalysisButton.trailingAnchor constraintEqualToAnchor:self.startMergeButton.leadingAnchor constant:-12]];
    [c addObject:[self.startAnalysisButton.widthAnchor constraintEqualToAnchor:self.startMergeButton.widthAnchor]];
    [c addObject:[self.startAnalysisButton.widthAnchor constraintLessThanOrEqualToConstant:130]];
    [c addObject:[self.startMergeButton.widthAnchor constraintLessThanOrEqualToConstant:130]];

    // ---- 显示区：从视图底部往上排 ----
    // 状态栏（底部）：进度条 + 状态文字 + 取消按钮
    [c addObject:[self.progressBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16]];
    [c addObject:[self.progressBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-10]];
    [c addObject:[self.statusLabel.leadingAnchor constraintEqualToAnchor:self.progressBar.trailingAnchor constant:10]];
    [c addObject:[self.statusLabel.centerYAnchor constraintEqualToAnchor:self.progressBar.centerYAnchor]];
    [c addObject:[self.cancelButton.centerYAnchor constraintEqualToAnchor:self.progressBar.centerYAnchor]];
    [c addObject:[self.cancelButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]];
    [c addObject:[self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.cancelButton.leadingAnchor constant:-12]];
    [c addObject:[self.progressBar.widthAnchor constraintGreaterThanOrEqualToConstant:200]];

    // 日志区
    [c addObject:[self.logScrollView.topAnchor constraintEqualToAnchor:self.estimatedStatsLabel.bottomAnchor constant:8]];
    [c addObject:[self.logScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16]];
    [c addObject:[self.logScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]];
    [c addObject:[self.logScrollView.bottomAnchor constraintEqualToAnchor:self.progressBar.topAnchor constant:-10]];

    // 三个统计标签（纵排）+ 右侧操作按钮组
    [c addObject:[self.primaryStatsLabel.topAnchor constraintEqualToAnchor:self.finalField.bottomAnchor constant:14]];
    [c addObject:[self.primaryStatsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16]];
    [c addObject:[self.primaryStatsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.startAnalysisButton.leadingAnchor constant:-12]];
    [c addObject:[self.secondaryStatsLabel.topAnchor constraintEqualToAnchor:self.primaryStatsLabel.bottomAnchor constant:3]];
    [c addObject:[self.secondaryStatsLabel.leadingAnchor constraintEqualToAnchor:self.primaryStatsLabel.leadingAnchor]];
    [c addObject:[self.secondaryStatsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.startAnalysisButton.leadingAnchor constant:-12]];
    [c addObject:[self.estimatedStatsLabel.topAnchor constraintEqualToAnchor:self.secondaryStatsLabel.bottomAnchor constant:3]];
    [c addObject:[self.estimatedStatsLabel.leadingAnchor constraintEqualToAnchor:self.primaryStatsLabel.leadingAnchor]];
    [c addObject:[self.estimatedStatsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.startAnalysisButton.leadingAnchor constant:-12]];
    // 操作按钮组垂直居中于三行标签（即中间行「副目录」）
    [c addObject:[self.startAnalysisButton.centerYAnchor constraintEqualToAnchor:self.secondaryStatsLabel.centerYAnchor]];
    [c addObject:[self.startMergeButton.centerYAnchor constraintEqualToAnchor:self.secondaryStatsLabel.centerYAnchor]];
    [c addObject:[self.startMergeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]];
    [c addObject:[self.startMergeButton.widthAnchor constraintGreaterThanOrEqualToConstant:100]];

    // ---- 布局比例：配置区高 1/3，显示区 2/3 ----
    // 通过"统计条顶部 = 最终目录底部 + 14"隐式划分；再显式约束：
    // 日志底部到状态栏的间隙由内容撑起，这里保证日志区至少有显示区的主体高度
    [c addObject:[self.logScrollView.heightAnchor
                  constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor
                  multiplier:2.0 / 3.0 constant:-80]];

    [NSLayoutConstraint activateConstraints:c];
}

#pragma mark 控件工厂

+ (NSTextField *)makePathField {
    NSTextField *f = [[NSTextField alloc] init];
    f.placeholderString = @"未选择";
    f.editable = NO;
    f.bezeled = YES;
    f.bezelStyle = NSTextFieldSquareBezel;
    f.lineBreakMode = NSLineBreakByTruncatingHead;
    f.cell.scrollable = YES;
    return f;
}

+ (NSTextField *)makeStatsLabel {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    l.maximumNumberOfLines = 1;
    l.cell.wraps = NO;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

+ (NSTextField *)makeRowLabel:(NSString *)title {
    NSTextField *l = [NSTextField labelWithString:title];
    l.alignment = NSTextAlignmentRight;
    l.textColor = [NSColor secondaryLabelColor];
    return l;
}

+ (NSButton *)makePickButtonWithTag:(NSInteger)tag target:(id)target {
    NSButton *b = [NSButton buttonWithTitle:@"浏览…" target:target action:@selector(pickDirectory:)];
    b.tag = tag;
    return b;
}

+ (NSButton *)makeButton:(NSString *)title tag:(NSInteger)tag target:(id)target {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:@selector(actionButtonClicked:)];
    b.tag = tag;
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

#pragma mark 事件

- (void)pickDirectory:(NSButton *)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"选择";
    // 以窗口 sheet 方式呈现，避免对已激活应用调用 activate 导致面板被取消
    NSWindow *window = self.view.window;
    if (!window) return;
    [panel beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URL.path;
        if (path.length == 0) return;
        switch (sender.tag) {
            case 0:
                self.viewModel.primaryPath = path;
                self.primaryField.stringValue = path;
                [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"FMPrimaryPath"];
                break;
            case 1:
                self.viewModel.secondaryPath = path;
                self.secondaryField.stringValue = path;
                [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"FMSecondaryPath"];
                break;
            case 2:
                self.viewModel.finalPath = path;
                self.finalField.stringValue = path;
                [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"FMFinalPath"];
                break;
            default:
                break;
        }
        // 已分析状态下更换目录：原分析结果不再匹配新目录，立即失效并回到空闲
        [self.viewModel resetAnalysis];
        [self refreshUI];
    }];
}

- (void)actionButtonClicked:(NSButton *)sender {
    switch (sender.tag) {
        case 3:  // 开始分析
            [self.viewModel startAnalysis];
            [self refreshUI];
            break;
        case 4:  // 开始合并
            [self.viewModel startMerge];
            [self refreshUI];
            break;
        default:
            break;
    }
}

- (void)cancelClicked:(NSButton *)sender {
    (void)sender;
    [self.viewModel cancel];
}

#pragma mark 刷新

- (void)refreshUI {
    FMAnalysisResult *result = self.viewModel.result;

    if (result) {
        self.primaryStatsLabel.stringValue = [NSString stringWithFormat:@"主目录：%lu 个文件 · 合计 %@",
                                              (unsigned long)result.primaryStats.fileCount,
                                              FMHumanBytes(result.primaryStats.totalBytes)];
        self.secondaryStatsLabel.stringValue = [NSString stringWithFormat:@"副目录：%lu 个文件 · 合计 %@",
                                                (unsigned long)result.secondaryStats.fileCount,
                                                FMHumanBytes(result.secondaryStats.totalBytes)];
        NSString *dupText = result.duplicateCount > 0
            ? [NSString stringWithFormat:@" · 剔除重复 %lu 个", (unsigned long)result.duplicateCount]
            : @"";
        self.estimatedStatsLabel.stringValue = [NSString stringWithFormat:@"预计合并后：%lu 个文件 · 合计 %@%@",
                                                (unsigned long)result.estimatedStats.fileCount,
                                                FMHumanBytes(result.estimatedStats.totalBytes),
                                                dupText];
    } else {
        self.primaryStatsLabel.stringValue = @"主目录：尚未分析";
        self.secondaryStatsLabel.stringValue = @"副目录：尚未分析";
        self.estimatedStatsLabel.stringValue = @"预计合并后：请选择目录后点击「开始分析」";
    }

    double p = self.viewModel.progress;
    self.progressBar.doubleValue = p;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%d%% · %@",
                                    (int)round(p * 100.0), self.viewModel.phaseText];

    BOOL canPick = self.viewModel.canPickDirectories;
    self.pickPrimaryButton.enabled = canPick;
    self.pickSecondaryButton.enabled = canPick;
    self.pickFinalButton.enabled = canPick;
    self.startAnalysisButton.enabled = self.viewModel.canStartAnalysis;
    self.startMergeButton.enabled = self.viewModel.canStartMerge;
    // 取消按钮：仅分析中/合并中可用
    FMAppState st = self.viewModel.state;
    self.cancelButton.enabled = (st == FMAppStateAnalyzing || st == FMAppStateMerging);
}

- (void)appendLogLine:(NSString *)line {
    NSTextView *tv = self.logView;
    // 近底部才自动滚动，避免打断用户回看
    NSScrollView *scrollView = self.logScrollView;
    BOOL nearBottom = NO;
    NSClipView *clip = scrollView.contentView;
    CGFloat documentHeight = tv.frame.size.height;
    CGFloat visibleBottom = clip.bounds.origin.y + clip.bounds.size.height;
    if (documentHeight <= 0 || visibleBottom >= documentHeight - 40.0) nearBottom = YES;

    NSDateFormatter *fmt = FMLogFormatter();
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *text = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };
    [[tv textStorage] appendAttributedString:
     [[NSAttributedString alloc] initWithString:text attributes:attrs]];

    // 日志上限：保留最近约 2000 条，避免海量日志无限增长拖垮内存与布局
    _logLineCount++;
    if (_logLineCount > 2100) {
        NSString *s = tv.textStorage.string;
        NSUInteger cut = 0;
        for (NSUInteger i = 0; i < 200 && cut < s.length; i++) {
            NSRange r = [s rangeOfString:@"\n" options:0 range:NSMakeRange(cut, s.length - cut)];
            if (r.location == NSNotFound) { cut = s.length; break; }
            cut = r.location + 1;
        }
        if (cut > 0) {
            [[tv textStorage] deleteCharactersInRange:NSMakeRange(0, cut)];
            _logLineCount -= 200;
        }
    }

    // documentView 宽度对齐可视宽度（autoresizing 触发时序不可靠），再按内容调整高度
    CGFloat visWidth = scrollView.contentView.bounds.size.width;
    if (visWidth > 0 && fabs(tv.frame.size.width - visWidth) > 0.5) {
        [tv setFrameSize:NSMakeSize(visWidth, tv.frame.size.height)];
    }
    [tv sizeToFit];

    if (nearBottom) {
        [tv scrollRangeToVisible:NSMakeRange(tv.string.length, 0)];
    }
}

#pragma mark FMAppViewModelDelegate（回调在主队列）

- (void)viewModelDidChange:(FMAppViewModel *)viewModel {
    (void)viewModel;
    [self refreshUI];
}

- (void)viewModel:(FMAppViewModel *)viewModel didAppendLogLine:(NSString *)line {
    (void)viewModel;
    [self appendLogLine:line];
}

@end

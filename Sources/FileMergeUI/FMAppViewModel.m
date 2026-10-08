#import "FMAppViewModel.h"

#import "FMError.h"
#import "FMModels.h"
#import "FMFileScanner.h"
#import "FMDedupEngine.h"
#import "FMMergeEngine.h"
#import "FMMergeValidator.h"
#import "FMFileHasher.h"
#import "FMProgressReporter.h"

#pragma mark - 工具

/// 人类可读的字节数描述
static NSString *FMBytesDescription(unsigned long long bytes) {
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

#pragma mark - 私有扩展

@interface FMAppViewModel ()
{
    NSLock *_lock;
    FMAppState _state;
    double _progress;
    NSString *_phaseText;
    FMAnalysisResult *_result;
    BOOL _busy;                       // 防止分析/合并重入
    BOOL _cancelRequested;            // 用户请求取消（引擎在文件粒度轮询）
    dispatch_queue_t _workQueue;      // 串行工作队列（扫描/排重/合并）
    FMFileHasher *_analysisHasher;    // 分析阶段哈希器（合并计划期复用缓存，仅在 _workQueue 上访问）
}
/// 取消标志读取（线程安全；供引擎的 isCancelled 块调用）
- (BOOL)cancelRequested;
@end

#pragma mark - 实现

@implementation FMAppViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _state = FMAppStateIdle;
        _progress = 0.0;
        _phaseText = @"就绪";
        _workQueue = dispatch_queue_create("com.filemerge.viewmodel.work", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark 只读属性（线程安全）

- (FMAppState)state {
    [_lock lock];
    FMAppState s = _state;
    [_lock unlock];
    return s;
}

- (double)progress {
    [_lock lock];
    double p = _progress;
    [_lock unlock];
    return p;
}

- (NSString *)phaseText {
    [_lock lock];
    NSString *t = _phaseText;
    [_lock unlock];
    return t;
}

- (FMAnalysisResult *)result {
    [_lock lock];
    FMAnalysisResult *r = _result;
    [_lock unlock];
    return r;
}

- (BOOL)canPickDirectories {
    FMAppState s = self.state;
    return s == FMAppStateIdle || s == FMAppStateAnalyzed;
}

- (BOOL)canStartAnalysis {
    if (!(self.state == FMAppStateIdle || self.state == FMAppStateAnalyzed)) return NO;
    return self.primaryPath.length > 0 && self.secondaryPath.length > 0 && self.finalPath.length > 0;
}

- (BOOL)canStartMerge {
    return self.state == FMAppStateAnalyzed;
}

#pragma mark 状态变更通知

- (void)notifyChange {
    dispatch_queue_t q = self.callbackQueue ?: dispatch_get_main_queue();
    dispatch_async(q, ^{
        [self.delegate viewModelDidChange:self];
    });
}

- (void)appendLog:(NSString *)line {
    dispatch_queue_t q = self.callbackQueue ?: dispatch_get_main_queue();
    dispatch_async(q, ^{
        [self.delegate viewModel:self didAppendLogLine:line];
    });
}

- (void)setProgressFraction:(double)fraction {
    [_lock lock];
    _progress = fraction;
    [_lock unlock];
    [self notifyChange];
}

- (void)setPhase:(NSString *)phase {
    [_lock lock];
    _phaseText = phase;
    [_lock unlock];
    [self notifyChange];
}

- (void)transitionToState:(FMAppState)state
                 progress:(double)progress
                    phase:(NSString *)phase {
    [_lock lock];
    _state = state;
    _progress = progress;
    _phaseText = phase;
    // Idle（一轮结束/失败）与 Analyzed（分析结束）均为操作完成的终态
    if (state == FMAppStateIdle || state == FMAppStateAnalyzed) {
        _busy = NO;
    }
    [_lock unlock];
    [self notifyChange];
}

- (BOOL)cancelRequested {
    [_lock lock];
    BOOL c = _cancelRequested;
    [_lock unlock];
    return c;
}

/// 请求取消当前分析/合并：忙碌时置标志；空闲为无操作
- (void)cancel {
    [_lock lock];
    BOOL busy = _busy;
    if (busy) _cancelRequested = YES;
    [_lock unlock];
    if (busy) {
        [self appendLog:@"已请求取消，等待当前文件处理完成…"];
    }
}

/// 使当前分析结果失效并回到空闲（已分析状态下更换目录时调用；其余状态为无操作）
- (void)resetAnalysis {
    [_lock lock];
    BOOL analyzed = (_state == FMAppStateAnalyzed && _result != nil);
    if (analyzed) _result = nil;
    [_lock unlock];
    if (!analyzed) return;
    [self transitionToState:FMAppStateIdle progress:0.0 phase:@"就绪"];
    [self appendLog:@"目录已变更，原分析结果已失效，请重新分析"];
}

/// 失败/取消分流：取消回到空闲并提示"已取消"；失败记录错误并回到空闲
- (void)failWithError:(nullable NSError *)error phasePrefix:(NSString *)prefix {
    BOOL cancelled = (error != nil
                      && [error.domain isEqualToString:FMErrorDomain]
                      && error.code == FMErrorCancelled);
    if (cancelled) {
        [self transitionToState:FMAppStateIdle progress:0.0 phase:[prefix stringByAppendingString:@"已取消"]];
        [self appendLog:[NSString stringWithFormat:@"%@：已取消", prefix]];
    } else {
        [self transitionToState:FMAppStateIdle progress:0.0 phase:[prefix stringByAppendingString:@"失败"]];
        [self appendLog:[NSString stringWithFormat:@"%@：%@", prefix, error.localizedDescription ?: @"未知错误"]];
    }
}

#pragma mark 开始分析

- (void)startAnalysis {
    NSString *primary = self.primaryPath;
    NSString *secondary = self.secondaryPath;
    NSString *finalRoot = self.finalPath;

    [_lock lock];
    if (_busy) {
        [_lock unlock];
        return;
    }
    if (primary.length == 0 || secondary.length == 0 || finalRoot.length == 0) {
        [_lock unlock];
        [self appendLog:@"请先选择主目录、副目录和最终目录"];
        return;
    }
    _busy = YES;
    _cancelRequested = NO;
    [_lock unlock];

    [self transitionToState:FMAppStateAnalyzing progress:0.0 phase:@"准备分析…"];

    dispatch_async(_workQueue, ^{
        [self runAnalysisWithPrimary:primary secondary:secondary finalRoot:finalRoot];
    });
}

- (void)runAnalysisWithPrimary:(NSString *)primary
                     secondary:(NSString *)secondary
                     finalRoot:(NSString *)finalRoot {
    [self appendLog:[NSString stringWithFormat:@"开始分析：主目录 %@ · 副目录 %@ · 最终目录 %@",
                     primary, secondary, finalRoot]];

    // 引擎在文件粒度轮询该块，实现随时可取消
    BOOL (^checkCancelled)(void) = ^{ return [self cancelRequested]; };

    // 1) 安全校验（祖先/后代、符号链接别名、大小写别名）
    NSError *verr = [FMMergeValidator validatePrimary:primary secondary:secondary final:finalRoot];
    if (verr) {
        [self failWithError:verr phasePrefix:@"分析"];
        return;
    }

    NSError *err = nil;
    FMFileScanner *scanner = [[FMFileScanner alloc] init];

    // 2) 扫描：总进度 0–20%（每根目录占 0.1）。
    //    不能让扫描阶段独立达到 1.0——进度上报器的单调钳制会把后续哈希阶段
    //    全程钉在 100%，而哈希恰是最耗时的阶段
    [self setPhase:@"正在扫描主目录…"];
    [self appendLog:@"正在扫描主目录…"];
    FMScanResult *scanP = [scanner scanRoot:primary origin:FMFileOriginPrimary cancelled:checkCancelled error:&err];
    if (!scanP) {
        [self failWithError:err phasePrefix:@"分析"];
        return;
    }
    for (NSString *w in scanP.warnings) [self appendLog:w];
    [self setProgressFraction:0.1];

    [self setPhase:@"正在扫描副目录…"];
    [self appendLog:@"正在扫描副目录…"];
    FMScanResult *scanS = [scanner scanRoot:secondary origin:FMFileOriginSecondary cancelled:checkCancelled error:&err];
    if (!scanS) {
        [self failWithError:err phasePrefix:@"分析"];
        return;
    }
    for (NSString *w in scanS.warnings) [self appendLog:w];
    [self setProgressFraction:0.2];

    // 3) 全局排重（引擎内部按哈希工作量扩展总量并上报）；
    //    排重进度映射为总进度 20%–100%，与扫描段衔接后单调递增
    [self setPhase:@"正在哈希排重…"];
    [self appendLog:[NSString stringWithFormat:@"正在哈希排重（主 %lu 个 + 副 %lu 个文件）…",
                     (unsigned long)scanP.fileCount, (unsigned long)scanS.fileCount]];
    FMFileHasher *hasher = [[FMFileHasher alloc] init];
    FMDedupEngine *dedup = [[FMDedupEngine alloc] init];
    FMProgressReporter *dedupProgress = [[FMProgressReporter alloc] initWithInterval:0.1 handler:
                                         ^(double fraction, NSUInteger completed, NSUInteger total) {
        [self setProgressFraction:0.2 + fraction * 0.8];
    }];
    FMDedupResult *dr = [dedup dedupPrimary:scanP.files
                                  secondary:scanS.files
                                     hasher:hasher
                                   progress:dedupProgress
                                  cancelled:checkCancelled
                                      error:&err];
    if (!dr) {
        [self failWithError:err phasePrefix:@"分析"];
        return;
    }
    // 哈希失败等被排除的文件必须可见
    for (NSString *w in dr.warnings) [self appendLog:w];
    // 供合并计划期复用哈希缓存（串行工作队列上读写，无需加锁）
    _analysisHasher = hasher;

    // 4) 汇总统计与预估结果
    unsigned long long estBytes = 0;
    for (FMFileRecord *r in dr.uniquePrimary) estBytes += r.fileSize;
    for (FMFileRecord *r in dr.uniqueSecondary) estBytes += r.fileSize;
    NSUInteger uniqueCount = dr.uniquePrimary.count + dr.uniqueSecondary.count;

    FMAnalysisResult *result = [[FMAnalysisResult alloc]
                                initWithUniquePrimary:dr.uniquePrimary
                                uniqueSecondary:dr.uniqueSecondary
                                primaryStats:[FMAnalysisStats statsWithCount:scanP.fileCount bytes:scanP.totalBytes]
                                secondaryStats:[FMAnalysisStats statsWithCount:scanS.fileCount bytes:scanS.totalBytes]
                                estimatedStats:[FMAnalysisStats statsWithCount:uniqueCount bytes:estBytes]
                                duplicateCount:dr.duplicateCount];

    [_lock lock];
    _result = result;
    [_lock unlock];
    [self transitionToState:FMAppStateAnalyzed progress:1.0 phase:@"分析完成"];

    [self appendLog:[NSString stringWithFormat:
                     @"分析完成 · 主目录 %lu 个文件（%@）· 副目录 %lu 个文件（%@）",
                     (unsigned long)scanP.fileCount, FMBytesDescription(scanP.totalBytes),
                     (unsigned long)scanS.fileCount, FMBytesDescription(scanS.totalBytes)]];
    [self appendLog:[NSString stringWithFormat:
                     @"排重后全局唯一 %lu 个文件（%@）· 剔除重复 %lu 个 · 预估最终目录 %@",
                     (unsigned long)uniqueCount, FMBytesDescription(estBytes),
                     (unsigned long)dr.duplicateCount, finalRoot]];
}

#pragma mark 开始合并

- (void)startMerge {
    [_lock lock];
    if (_busy || _state != FMAppStateAnalyzed || !_result) {
        [_lock unlock];
        return;
    }
    _busy = YES;
    _cancelRequested = NO;
    FMAnalysisResult *result = _result;
    [_lock unlock];
    NSString *finalRoot = self.finalPath;

    [self transitionToState:FMAppStateMerging progress:0.0 phase:@"正在构建合并计划…"];
    [self appendLog:[NSString stringWithFormat:@"开始合并：目标目录 %@", finalRoot]];

    dispatch_async(_workQueue, ^{
        [self runMergeWithResult:result finalRoot:finalRoot];
    });
}

- (void)runMergeWithResult:(FMAnalysisResult *)result finalRoot:(NSString *)finalRoot {
    BOOL (^checkCancelled)(void) = ^{ return [self cancelRequested]; };

    // 合并前复检安全校验：分析之后外部环境可能变化（如最终目录被替换为
    // 指向主/副目录的符号链接或其祖先），写入前必须重新确认无自我覆盖风险
    NSError *verr = [FMMergeValidator validatePrimary:self.primaryPath
                                            secondary:self.secondaryPath
                                                 final:finalRoot];
    if (verr) {
        [self failWithError:verr phasePrefix:@"合并"];
        return;
    }

    // 复用分析阶段的哈希器：计划期内容比较直接命中排重时的哈希缓存，
    // 避免对已知文件重新全量读取
    FMMergeEngine *engine = [[FMMergeEngine alloc] initWithHasher:_analysisHasher workerCount:0];
    NSArray<FMMergePlanItem *> *plan = [engine buildPlanPrimary:result.uniquePrimary
                                                      secondary:result.uniqueSecondary
                                                      finalRoot:finalRoot
                                                      cancelled:checkCancelled];
    if ([self cancelRequested]) {
        // 计划构建中途取消：计划可能不完整，按取消处理
        [self failWithError:[NSError errorWithDomain:FMErrorDomain code:FMErrorCancelled
                                          userInfo:@{NSLocalizedDescriptionKey : @"已取消"}]
                phasePrefix:@"合并"];
        return;
    }

    // 计划分类统计（过程可见性）
    NSUInteger planCopy = 0, planOverwrite = 0, planSkip = 0, planRename = 0, planReject = 0;
    for (FMMergePlanItem *item in plan) {
        switch (item.action) {
            case FMPlanActionCopy:      planCopy++;      break;
            case FMPlanActionOverwrite: planOverwrite++; break;
            case FMPlanActionSkip:      planSkip++;      break;
            case FMPlanActionRename:    planRename++;    break;
            case FMPlanActionError:     planReject++;    break;
        }
    }
    [self appendLog:[NSString stringWithFormat:@"合并计划（共 %lu 项）：写入 %lu · 覆盖 %lu · 跳过 %lu · 重命名 %lu · 拒绝 %lu",
                     (unsigned long)plan.count, (unsigned long)planCopy, (unsigned long)planOverwrite,
                     (unsigned long)planSkip, (unsigned long)planRename, (unsigned long)planReject]];

    FMMergeOutcome *outcome = nil;
    if (plan.count > 0) {
        [self setPhase:[NSString stringWithFormat:@"正在合并 %lu 个文件…", (unsigned long)plan.count]];
        [self appendLog:[NSString stringWithFormat:@"正在执行合并计划（共 %lu 项操作）…", (unsigned long)plan.count]];
        FMProgressReporter *progress = [[FMProgressReporter alloc] initWithInterval:0.1 handler:
                                        ^(double fraction, NSUInteger completed, NSUInteger total) {
            [self setProgressFraction:fraction];
        }];
        // 总量由引擎按实际写盘条目 expandTotalBy: 扩展（此处不预加，避免双计
        // 导致进度最多只走到 50% 再由 finish 跳满）

        NSError *err = nil;
        outcome = [engine executePlan:plan progress:progress cancelled:checkCancelled error:&err];
        if (!outcome) {
            [self failWithError:err phasePrefix:@"合并"];
            return;
        }
    } else {
        [self appendLog:@"最终目录已是最新，无需复制操作"];
    }

    [self transitionToState:FMAppStateIdle progress:1.0 phase:@"合并完成"];

    [self appendLog:[NSString stringWithFormat:
                     @"合并完成 · 写入 %lu · 覆盖 %lu · 跳过 %lu · 重命名 %lu · 错误 %lu",
                     (unsigned long)outcome.copiedCount, (unsigned long)outcome.overwrittenCount,
                     (unsigned long)outcome.skippedCount, (unsigned long)outcome.renamedCount,
                     (unsigned long)outcome.errorCount]];
    for (NSString *m in outcome.errorMessages) [self appendLog:m];
}

@end

#import "FMMergeEngine.h"
#import "FMError.h"
#import <sys/sysctl.h>

#pragma mark - 计划条目

@interface FMMergePlanItem ()
@end

@implementation FMMergePlanItem {
    FMPlanAction _action;
    FMFileRecord *_source;
    NSString *_targetPath;
    NSString *_errorMessage;
}

- (instancetype)initWithAction:(FMPlanAction)action
                        source:(FMFileRecord *)source
                    targetPath:(NSString *)targetPath
                  errorMessage:(nullable NSString *)errorMessage {
    self = [super init];
    if (self) {
        _action = action;
        _source = source;
        _targetPath = [targetPath copy];
        _errorMessage = [errorMessage copy];
    }
    return self;
}

@end

#pragma mark - 执行结果

@interface FMMergeOutcome ()
@end

@implementation FMMergeOutcome {
    NSUInteger _copied;
    NSUInteger _overwritten;
    NSUInteger _skipped;
    NSUInteger _renamed;
    NSUInteger _errors;
    NSArray<NSString *> *_errorMessages;
}

- (instancetype)initWithCopied:(NSUInteger)copied
                    overwritten:(NSUInteger)overwritten
                        skipped:(NSUInteger)skipped
                        renamed:(NSUInteger)renamed
                         errors:(NSUInteger)errors
                  errorMessages:(NSArray<NSString *> *)errorMessages {
    self = [super init];
    if (self) {
        _copied = copied;
        _overwritten = overwritten;
        _skipped = skipped;
        _renamed = renamed;
        _errors = errors;
        _errorMessages = [errorMessages copy] ?: @[];
    }
    return self;
}

- (NSUInteger)copiedCount { return _copied; }
- (NSUInteger)overwrittenCount { return _overwritten; }
- (NSUInteger)skippedCount { return _skipped; }
- (NSUInteger)renamedCount { return _renamed; }
- (NSUInteger)errorCount { return _errors; }
- (NSArray<NSString *> *)errorMessages { return _errorMessages; }

@end

#pragma mark - FMMergeEngine

static NSUInteger FMDefaultWorkers(void) {
    size_t len = sizeof(uint32_t);
    uint32_t cores = 4;
    sysctlbyname("hw.ncpu", &cores, &len, NULL, 0);
    NSUInteger n = (NSUInteger)cores;
    if (n < 4) n = 4;
    if (n > 16) n = 16;
    return n;
}

static void FMFillError(NSError **error, FMErrorCode code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:FMErrorDomain code:code
                              userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
    }
}

@interface FMMergeEngine ()
@end

@implementation FMMergeEngine {
    FMFileHasher *_hasher;
    NSUInteger _workers;
}

- (instancetype)initWithHasher:(FMFileHasher *)hasher workerCount:(NSUInteger)workers {
    self = [super init];
    if (self) {
        _hasher = hasher ?: [[FMFileHasher alloc] init];
        if (workers < 2) {
            _workers = FMDefaultWorkers();
        } else if (workers > 16) {
            _workers = 16;
        } else {
            _workers = workers;
        }
    }
    return self;
}

- (instancetype)init {
    return [self initWithHasher:nil workerCount:0];
}

#pragma mark 第一步：串行决策（干跑，不写入）

- (NSArray<FMMergePlanItem *> *)buildPlanPrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                                       secondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                                       finalRoot:(NSString *)finalRoot
                                       cancelled:(nullable BOOL (^)(void))isCancelled {
    NSMutableArray<FMMergePlanItem *> *plan = [NSMutableArray array];
    if (isCancelled && isCancelled()) return [plan copy];

    // 占用表：已被"本次计划写入"或"磁盘已存在"的相对路径
    // 对主目录条目：目标相对路径即 rel
    // 对副目录条目：需要检查冲突并可能重命名
    NSMutableDictionary<NSString *, FMFileRecord *> *plannedSources = [NSMutableDictionary dictionary]; // rel → 决定写入的源
    NSMutableSet<NSString *> *occupied = [NSMutableSet set];  // 已被占用的绝对目标路径

    NSFileManager *fm = [NSFileManager defaultManager];

    // 主目录条目：主目录优先
    for (FMFileRecord *record in uniquePrimary) {
        if (isCancelled && isCancelled()) return [plan copy];
        NSString *target = [finalRoot stringByAppendingPathComponent:record.relativePath];
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:target isDirectory:&isDir];

        if (exists && isDir) {
            // 覆盖目标为目录：拒绝执行并记录错误，防止递归删除子树
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionError
                                                             source:record
                                                         targetPath:target
                                                       errorMessage:[NSString stringWithFormat:@"目标路径是目录，拒绝覆盖: %@", target]]];
            [occupied addObject:target];
            continue;
        }

        if (!exists) {
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionCopy source:record targetPath:target errorMessage:nil]];
        } else if ([self contentOfRecord:record matchesPath:target]) {
            // 目标已存在且内容相同 → 跳过（幂等）
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionSkip source:record targetPath:target errorMessage:nil]];
        } else {
            // 主目录文件覆盖目标中同名不同内容文件
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionOverwrite source:record targetPath:target errorMessage:nil]];
        }
        [occupied addObject:target];
        plannedSources[record.relativePath] = record;
    }

    // 副目录条目
    for (FMFileRecord *record in uniqueSecondary) {
        if (isCancelled && isCancelled()) return [plan copy];
        NSString *target = [finalRoot stringByAppendingPathComponent:record.relativePath];
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:target isDirectory:&isDir];

        // 磁盘上不存在且未被本计划占用 → 直接复制
        if (!exists && ![occupied containsObject:target]) {
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionCopy source:record targetPath:target errorMessage:nil]];
            [occupied addObject:target];
            plannedSources[record.relativePath] = record;
            continue;
        }

        // 目标已存在（磁盘已有或本计划将写入）：内容一致 → 幂等跳过；否则重命名
        BOOL identical = NO;
        if (exists && !isDir) {
            identical = [self contentOfRecord:record matchesPath:target];
        } else if (!exists) {
            // 目标由本次计划写入：与计划的源比较内容
            FMFileRecord *planned = plannedSources[record.relativePath];
            if (planned) {
                identical = [self contentOfRecord:record matchesRecord:planned];
            }
        }

        if (identical) {
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionSkip source:record targetPath:target errorMessage:nil]];
            continue;
        }

        // 冲突 → 生成 "名称 (n).ext" 候选
        BOOL resolved = NO;
        for (NSUInteger n = 1; n <= 9999 && !resolved; n++) {
            NSString *candidate = [FMMergeEngine conflictRenamedPathForPath:target index:n];
            BOOL cIsDir = NO;
            BOOL cExists = [fm fileExistsAtPath:candidate isDirectory:&cIsDir];

            if (!cExists && ![occupied containsObject:candidate]) {
                [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionRename source:record targetPath:candidate errorMessage:nil]];
                [occupied addObject:candidate];
                resolved = YES;
            } else if (cExists && !cIsDir && [self contentOfRecord:record matchesPath:candidate]) {
                // 重命名目标已存在且内容一致（重复合并场景）→ 幂等跳过，不产生冗余副本
                [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionSkip source:record targetPath:candidate errorMessage:nil]];
                resolved = YES;
            }
            // 否则尝试下一个序号
        }
        if (!resolved) {
            [plan addObject:[[FMMergePlanItem alloc] initWithAction:FMPlanActionError
                                                             source:record
                                                         targetPath:target
                                                       errorMessage:[NSString stringWithFormat:@"无法为冲突文件生成重命名路径: %@", target]]];
        }
    }

    return [plan copy];
}

/// "名称 (n).ext"：在最后一个扩展名前插入 " (n)"
+ (NSString *)conflictRenamedPathForPath:(NSString *)path index:(NSUInteger)n {
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *base = [path lastPathComponent];
    NSString *ext = [base pathExtension];
    NSString *stem = ext.length > 0 ? [base substringToIndex:base.length - ext.length - 1] : base;
    NSString *newBase = ext.length > 0
        ? [NSString stringWithFormat:@"%@ (%llu).%@", stem, (unsigned long long)n, ext]
        : [NSString stringWithFormat:@"%@ (%llu)", stem, (unsigned long long)n];
    return dir.length > 0 ? [dir stringByAppendingPathComponent:newBase] : newBase;
}

#pragma mark 内容比较

/// record 的内容是否与 targetPath 处文件一致（尺寸先筛，全量哈希兜底）
- (BOOL)contentOfRecord:(FMFileRecord *)record matchesPath:(NSString *)targetPath {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:targetPath error:nil];
    if (!attrs || [attrs fileType] == NSFileTypeDirectory) return NO;
    unsigned long long tSize = [attrs fileSize];
    if (tSize != record.fileSize) return NO;  // 尺寸不同内容必不同

    FMFileRecord *targetRecord = [FMFileRecord recordWithOrigin:record.origin
                                                       rootPath:record.rootPath
                                                   relativePath:record.relativePath
                                                   absolutePath:targetPath
                                                       fileSize:tSize];
    NSError *err = nil;
    NSData *a = [_hasher fullHashForFile:record error:&err];
    if (!a) return NO;
    NSData *b = [_hasher fullHashForFile:targetRecord error:&err];
    if (!b) return NO;
    return [a isEqualToData:b];
}

/// 两条记录内容是否一致（尺寸先筛，全量哈希兜底；哈希结果有缓存）
- (BOOL)contentOfRecord:(FMFileRecord *)record matchesRecord:(FMFileRecord *)other {
    if (record.fileSize != other.fileSize) return NO;
    NSError *err = nil;
    NSData *a = [_hasher fullHashForFile:record error:&err];
    if (!a) return NO;
    NSData *b = [_hasher fullHashForFile:other error:&err];
    if (!b) return NO;
    return [a isEqualToData:b];
}

#pragma mark 第二步：有界并发执行

- (nullable FMMergeOutcome *)executePlan:(NSArray<FMMergePlanItem *> *)plan
                                progress:(nullable FMProgressReporter *)progress
                               cancelled:(nullable BOOL (^)(void))isCancelled
                                   error:(NSError **)error {
    if (isCancelled && isCancelled()) {
        FMFillError(error, FMErrorCancelled, @"合并已取消");
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // 仅执行需要写盘的条目
    NSMutableArray<FMMergePlanItem *> *workItems = [NSMutableArray array];
    for (FMMergePlanItem *item in plan) {
        switch (item.action) {
            case FMPlanActionCopy:
            case FMPlanActionOverwrite:
            case FMPlanActionRename:
                [workItems addObject:item];
                break;
            default:
                break;
        }
    }

    __block NSUInteger copied = 0;
    __block NSUInteger overwritten = 0;
    __block NSUInteger renamed = 0;
    __block NSUInteger errors = 0;
    __block NSUInteger skipped = 0;
    NSMutableArray<NSString *> *errorMessages = [NSMutableArray array];
    NSLock *counterLock = [[NSLock alloc] init];

    [progress expandTotalBy:workItems.count];

    // 取所有条目目标路径的公共前缀来创建目录：直接对每个条目按需创建父目录（幂等）
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(_workers);
    __block BOOL userCancelled = NO;

    dispatch_apply(workItems.count, queue, ^(size_t idx) {
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        @autoreleasepool {
            if (isCancelled && isCancelled()) {
                userCancelled = YES;
                dispatch_semaphore_signal(gate);
                return;
            }
            FMMergePlanItem *item = workItems[idx];
            NSString *target = item.targetPath;
            NSString *stepError = nil;  // 非空表示本条目失败（错误消息已构造）
            BOOL written = NO;

            // 1) 确保父目录存在（中间目录可能是文件时会失败并记错）
            NSError *mkErr = nil;
            if (![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&mkErr]) {
                stepError = [NSString stringWithFormat:@"创建目录失败 (%@): %@",
                             mkErr.localizedDescription ?: @"", target.stringByDeletingLastPathComponent];
            }

            // 2) 覆盖：先复制到同目录临时文件，再原子替换目标——
            //    避免中途失败（磁盘满/源不可读）时丢失旧文件
            if (!stepError && item.action == FMPlanActionOverwrite) {
                NSString *tmp = [NSString stringWithFormat:@"%@.fm-tmp-%lu", target, (unsigned long)idx];
                [fm removeItemAtPath:tmp error:nil];  // 清理可能的历史残留

                NSError *tmpErr = nil;
                if (![fm copyItemAtPath:item.source.absolutePath toPath:tmp error:&tmpErr]) {
                    stepError = [NSString stringWithFormat:@"复制失败 %@ → %@ (%@)",
                                 item.source.absolutePath, target, tmpErr.localizedDescription ?: @""];
                } else {
                    // 目标现状分流。注意：目录拒绝必须在替换之前判定——
                    // replaceItemAt 会无条件把目录换成文件，等于递归删除整个子树
                    BOOL isDir = NO;
                    BOOL tExists = [fm fileExistsAtPath:target isDirectory:&isDir];
                    BOOL replaced = NO;
                    if (tExists && isDir) {
                        // 计划后目标变成目录：拒绝覆盖（防止递归删除子树）
                        stepError = [NSString stringWithFormat:@"目标路径是目录，拒绝覆盖: %@", target];
                    } else if (tExists) {
                        // 原子替换（APFS 上为 rename 交换，目标不经历"已删未就位"空窗）；
                        // 失败退回"先删后移"——该分支仅剩极端文件系统错误，此时才可能出现旧文件丢失
                        NSError *repErr = nil;
                        if ([fm replaceItemAtURL:[NSURL fileURLWithPath:target]
                                   withItemAtURL:[NSURL fileURLWithPath:tmp]
                                  backupItemName:nil
                                         options:0
                                resultingItemURL:NULL
                                           error:&repErr]) {
                            replaced = YES;
                        } else {
                            NSError *rmErr = nil;
                            if (![fm removeItemAtPath:target error:&rmErr]) {
                                stepError = [NSString stringWithFormat:@"移除旧文件失败 (%@): %@",
                                             rmErr.localizedDescription ?: @"", target];
                            } else {
                                NSError *mvErr = nil;
                                if ([fm moveItemAtPath:tmp toPath:target error:&mvErr]) {
                                    replaced = YES;
                                } else {
                                    stepError = [NSString stringWithFormat:@"覆盖失败 %@ → %@ (%@)",
                                                 item.source.absolutePath, target, mvErr.localizedDescription ?: @""];
                                }
                            }
                        }
                    } else {
                        // 目标已被外部移除：直接将临时文件补位
                        NSError *mvErr = nil;
                        if ([fm moveItemAtPath:tmp toPath:target error:&mvErr]) {
                            replaced = YES;
                        } else {
                            stepError = [NSString stringWithFormat:@"覆盖失败 %@ → %@ (%@)",
                                         item.source.absolutePath, target, mvErr.localizedDescription ?: @""];
                        }
                    }
                    if (stepError) [fm removeItemAtPath:tmp error:nil];  // 清理临时文件，未成功不落位
                    if (replaced) written = YES;
                }
            }

            // 3) 常规写入（Copy/Rename：目标不应存在，直接复制）
            if (!stepError && !written) {
                NSError *copyErr = nil;
                if ([fm copyItemAtPath:item.source.absolutePath toPath:target error:&copyErr]) {
                    written = YES;
                } else {
                    stepError = [NSString stringWithFormat:@"复制失败 %@ → %@ (%@)",
                                 item.source.absolutePath, target, copyErr.localizedDescription ?: @""];
                }
            }

            if (written) {
                [counterLock lock];
                switch (item.action) {
                    case FMPlanActionCopy: copied++; break;
                    case FMPlanActionOverwrite: overwritten++; break;
                    case FMPlanActionRename: renamed++; break;
                    default: break;
                }
                [counterLock unlock];
            } else if (stepError) {
                [counterLock lock];
                errors++;
                [errorMessages addObject:stepError];
                [counterLock unlock];
            }
            [progress incrementCompleted];
        }
        dispatch_semaphore_signal(gate);
    });

    if (isCancelled && isCancelled()) {
        userCancelled = YES;
    }
    if (userCancelled) {
        FMFillError(error, FMErrorCancelled, @"合并已取消");
        return nil;
    }

    // 统计跳过数
    for (FMMergePlanItem *item in plan) {
        if (item.action == FMPlanActionSkip) skipped++;
    }
    // 计划期错误也计入
    for (FMMergePlanItem *item in plan) {
        if (item.action == FMPlanActionError) {
            errors++;
            if (item.errorMessage) [errorMessages addObject:item.errorMessage];
        }
    }

    [progress finish];
    return [[FMMergeOutcome alloc] initWithCopied:copied overwritten:overwritten skipped:skipped renamed:renamed errors:errors errorMessages:errorMessages];
}

@end

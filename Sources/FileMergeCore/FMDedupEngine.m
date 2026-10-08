#import "FMDedupEngine.h"
#import "FMError.h"
#import <sys/sysctl.h>

#pragma mark - 工具

static NSUInteger FMBoundedWorkerCount(void) {
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

static NSString *FMHex(NSData *data) {
    if (!data) return nil;
    const unsigned char *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

/// 重复组内保留次序：主目录优先；同源内按相对路径 Unicode 升序。
/// （并发哈希向桶中插入的顺序不确定，决策前必须重新排序保证可复现）
/// 不捕获任何变量的 block 为全局常量块，可安全用作静态 NSComparator
static NSComparator FMRecordComparator = ^NSComparisonResult(id a, id b) {
    FMFileRecord *ra = a;
    FMFileRecord *rb = b;
    if (ra.origin != rb.origin) {
        return ra.origin < rb.origin ? NSOrderedAscending : NSOrderedDescending;
    }
    return [ra.relativePath compare:rb.relativePath];
};

#pragma mark - FMDedupEngine

@interface FMDedupEngine ()
@end

@implementation FMDedupEngine

- (nullable FMDedupResult *)dedupPrimary:(NSArray<FMFileRecord *> *)primary
                               secondary:(NSArray<FMFileRecord *> *)secondary
                                  hasher:(FMFileHasher *)hasher
                                progress:(nullable FMProgressReporter *)progress
                               cancelled:(nullable BOOL (^)(void))isCancelled
                                   error:(NSError **)error {
    if (isCancelled && isCancelled()) {
        FMFillError(error, FMErrorCancelled, @"排重已取消");
        return nil;
    }

    // 主目录优先：主目录条目整体排在副目录之前；同源内按相对路径 Unicode 升序
    NSArray<FMFileRecord *> *sortedPrimary = [primary sortedArrayUsingComparator:^NSComparisonResult(FMFileRecord *a, FMFileRecord *b) {
        return [a.relativePath compare:b.relativePath];
    }];
    NSArray<FMFileRecord *> *sortedSecondary = [secondary sortedArrayUsingComparator:^NSComparisonResult(FMFileRecord *a, FMFileRecord *b) {
        return [a.relativePath compare:b.relativePath];
    }];
    NSArray<FMFileRecord *> *all = [sortedPrimary arrayByAddingObjectsFromArray:sortedSecondary];

    // 第一级：尺寸唯一 → 免哈希直接唯一
    NSMutableDictionary<NSNumber *, NSMutableArray<FMFileRecord *> *> *sizeBuckets = [NSMutableDictionary dictionary];
    for (FMFileRecord *record in all) {
        NSNumber *key = @(record.fileSize);
        if (!sizeBuckets[key]) sizeBuckets[key] = [NSMutableArray array];
        [sizeBuckets[key] addObject:record];
    }

    NSMutableSet<NSString *> *uniquePaths = [NSMutableSet set];   // 以绝对路径记录唯一条目
    NSUInteger duplicateCount = 0;
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];   // 哈希失败被排除的文件
    NSMutableSet<NSString *> *warnedPaths = [NSMutableSet set];      // 去重（同一文件只报一次）
    static const NSUInteger FMMaxDedupWarnings = 50;

    NSMutableArray<NSArray<FMFileRecord *> *> *pendingHeadGroups = [NSMutableArray array];
    for (NSNumber *sizeKey in sizeBuckets) {
        NSArray<FMFileRecord *> *bucket = sizeBuckets[sizeKey];
        if (bucket.count == 1) {
            [uniquePaths addObject:bucket.firstObject.absolutePath];
        } else {
            [pendingHeadGroups addObject:bucket];
            [progress expandTotalBy:bucket.count];  // 头部哈希阶段工作量
        }
    }

    NSUInteger workers = FMBoundedWorkerCount();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(workers);

    // 第二级：64KB 头部哈希预筛
    // key: size|headHex → 记录数组
    NSMutableDictionary<NSString *, NSMutableArray<FMFileRecord *> *> *headBuckets = [NSMutableDictionary dictionary];
    for (NSArray<FMFileRecord *> *group in pendingHeadGroups) {
        __block BOOL cancelled = NO;
        dispatch_apply(group.count, queue, ^(size_t idx) {
            dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
            @autoreleasepool {
                if (isCancelled && isCancelled()) {
                    cancelled = YES;
                    dispatch_semaphore_signal(gate);
                    return;
                }
                FMFileRecord *record = group[idx];
                NSError *hashErr = nil;
                NSData *head = [hasher headHashForFile:record error:&hashErr];
                if (head) {
                    NSString *key = [NSString stringWithFormat:@"%llu|%@", record.fileSize, FMHex(head)];
                    @synchronized(headBuckets) {
                        if (!headBuckets[key]) headBuckets[key] = [NSMutableArray array];
                        [headBuckets[key] addObject:record];
                    }
                } else {
                    // 哈希失败：文件被排除必须可见，不得静默消失
                    @synchronized(warnings) {
                        if (![warnedPaths containsObject:record.absolutePath]) {
                            [warnedPaths addObject:record.absolutePath];
                            if (warnings.count < FMMaxDedupWarnings) {
                                [warnings addObject:[NSString stringWithFormat:@"哈希失败，已排除: %@ (%@)",
                                                     record.absolutePath, hashErr.localizedDescription ?: @""]];
                            }
                        }
                    }
                }
                [progress incrementCompleted];
            }
            dispatch_semaphore_signal(gate);
        });
        if (cancelled || (isCancelled && isCancelled())) {
            FMFillError(error, FMErrorCancelled, @"排重已取消");
            return nil;
        }
    }

    // 头部哈希后仍无法区分的分组进入全量哈希
    NSMutableArray<NSArray<FMFileRecord *> *> *pendingFullGroups = [NSMutableArray array];
    for (NSString *key in headBuckets) {
        NSMutableArray<FMFileRecord *> *bucket = headBuckets[key];
        [bucket sortUsingComparator:FMRecordComparator];  // 消除并发插入顺序的不确定性
        if (bucket.count == 1) {
            [uniquePaths addObject:bucket.firstObject.absolutePath];
        } else {
            [pendingFullGroups addObject:bucket];
            [progress expandTotalBy:bucket.count];  // 全量哈希阶段工作量
        }
    }

    // 第三级：全量 SHA256 兜底
    for (NSArray<FMFileRecord *> *group in pendingFullGroups) {
        __block BOOL cancelled = NO;
        NSMutableDictionary<NSString *, NSMutableArray<FMFileRecord *> *> *fullBuckets = [NSMutableDictionary dictionary];
        dispatch_apply(group.count, queue, ^(size_t idx) {
            dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
            @autoreleasepool {
                if (isCancelled && isCancelled()) {
                    cancelled = YES;
                    dispatch_semaphore_signal(gate);
                    return;
                }
                FMFileRecord *record = group[idx];
                NSError *hashErr = nil;
                NSData *full = [hasher fullHashForFile:record error:&hashErr];
                if (full) {
                    NSString *key = FMHex(full);
                    @synchronized(fullBuckets) {
                        if (!fullBuckets[key]) fullBuckets[key] = [NSMutableArray array];
                        [fullBuckets[key] addObject:record];
                    }
                } else {
                    @synchronized(warnings) {
                        if (![warnedPaths containsObject:record.absolutePath]) {
                            [warnedPaths addObject:record.absolutePath];
                            if (warnings.count < FMMaxDedupWarnings) {
                                [warnings addObject:[NSString stringWithFormat:@"哈希失败，已排除: %@ (%@)",
                                                     record.absolutePath, hashErr.localizedDescription ?: @""]];
                            }
                        }
                    }
                }
                [progress incrementCompleted];
            }
            dispatch_semaphore_signal(gate);
        });
        if (cancelled || (isCancelled && isCancelled())) {
            FMFillError(error, FMErrorCancelled, @"排重已取消");
            return nil;
        }

        for (NSString *key in fullBuckets) {
            NSMutableArray<FMFileRecord *> *bucket = fullBuckets[key];
            [bucket sortUsingComparator:FMRecordComparator];  // 消除并发插入顺序的不确定性
            if (bucket.count == 1) {
                [uniquePaths addObject:bucket.firstObject.absolutePath];
            } else {
                // 经排序后取首个 = 主目录优先 + 相对路径 Unicode 升序
                [uniquePaths addObject:bucket.firstObject.absolutePath];
                duplicateCount += bucket.count - 1;
            }
        }
    }

    // 汇总（保持各自的 Unicode 升序）
    NSMutableArray<FMFileRecord *> *uniquePrimary = [NSMutableArray array];
    for (FMFileRecord *record in sortedPrimary) {
        if ([uniquePaths containsObject:record.absolutePath]) [uniquePrimary addObject:record];
    }
    NSMutableArray<FMFileRecord *> *uniqueSecondary = [NSMutableArray array];
    for (FMFileRecord *record in sortedSecondary) {
        if ([uniquePaths containsObject:record.absolutePath]) [uniqueSecondary addObject:record];
    }

    // 超出封顶的告警以汇总行提示
    if (warnedPaths.count > warnings.count) {
        [warnings addObject:[NSString stringWithFormat:@"……另有 %lu 个哈希失败文件未逐条列出",
                             (unsigned long)(warnedPaths.count - warnings.count)]];
    }

    [progress finish];
    return [[FMDedupResult alloc] initWithUniquePrimary:uniquePrimary
                                        uniqueSecondary:uniqueSecondary
                                         duplicateCount:duplicateCount
                                               warnings:warnings];
}

@end

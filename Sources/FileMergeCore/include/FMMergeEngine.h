#import <Foundation/Foundation.h>
#import "FMModels.h"
#import "FMFileHasher.h"
#import "FMProgressReporter.h"

NS_ASSUME_NONNULL_BEGIN

/// 合并计划动作
typedef NS_ENUM(NSInteger, FMPlanAction) {
    FMPlanActionCopy      = 0,  // 目标不存在 → 新写入
    FMPlanActionOverwrite = 1,  // 目标同名但内容不同 → 覆盖（主目录文件）
    FMPlanActionSkip      = 2,  // 目标已存在且内容相同 → 跳过（幂等）
    FMPlanActionRename    = 3,  // 目标冲突（内容不同）→ 重命名 "名称 (1).ext"
    FMPlanActionError     = 4,  // 拒绝执行（如覆盖目标为目录）
};

/// 合并计划条目（先串行决策，后并发执行）
@interface FMMergePlanItem : NSObject
@property (nonatomic, readonly) FMPlanAction action;
@property (nonatomic, readonly, strong) FMFileRecord *source;
/// 计划目标路径（重命名条目为最终采用的重命名路径）
@property (nonatomic, readonly, copy) NSString *targetPath;
/// 拒绝原因（action == FMPlanActionError 时非空）
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
@end

/// 合并执行结果统计
@interface FMMergeOutcome : NSObject
@property (nonatomic, readonly) NSUInteger copiedCount;
@property (nonatomic, readonly) NSUInteger overwrittenCount;
@property (nonatomic, readonly) NSUInteger skippedCount;
@property (nonatomic, readonly) NSUInteger renamedCount;
@property (nonatomic, readonly) NSUInteger errorCount;
@property (nonatomic, readonly, copy) NSArray<NSString *> *errorMessages;
@end

/// 合并引擎：两步走——先串行决策生成计划，再以有界并发执行复制
@interface FMMergeEngine : NSObject

/// workers 取值会被约束到 [2, 16]，默认 min(max(4, 核数), 16)
- (instancetype)initWithHasher:(nullable FMFileHasher *)hasher workerCount:(NSUInteger)workers NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

/// 第一步：串行决策。对主目录条目判定 写入/覆盖/跳过/拒绝；
/// 对副目录条目判定 写入/跳过/重命名/拒绝。此阶段读取目标目录现有状态并做内容比较。
/// cancelled 返回 YES 时尽早返回（结果可能不完整，调用方应随后检查取消状态）。
- (NSArray<FMMergePlanItem *> *)buildPlanPrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                                       secondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                                       finalRoot:(NSString *)finalRoot
                                       cancelled:(nullable BOOL (^)(void))isCancelled;

/// 第二步：并发执行计划（cancelled 返回 YES 时中止并返回 FMErrorCancelled）
- (nullable FMMergeOutcome *)executePlan:(NSArray<FMMergePlanItem *> *)plan
                                progress:(nullable FMProgressReporter *)progress
                               cancelled:(nullable BOOL (^)(void))isCancelled
                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

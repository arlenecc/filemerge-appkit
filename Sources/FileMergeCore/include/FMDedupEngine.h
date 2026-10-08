#import <Foundation/Foundation.h>
#import "FMModels.h"
#import "FMFileHasher.h"
#import "FMProgressReporter.h"

NS_ASSUME_NONNULL_BEGIN

/// 全局统一排重引擎：
/// - 在主/副两个目录的全部子目录间按文件哈希做全局唯一性判定
/// - 主目录优先：主/副同内容时保留主目录条目
/// - 同源内部重复：按相对路径 Unicode 升序保留第一个
/// - 三级去重：尺寸唯一免哈希 → 头部哈希预筛 → 全量 SHA256 兜底
/// - 哈希工作量为进度单元，分阶段 expandTotalBy: 上报
@interface FMDedupEngine : NSObject

/// @param primary   主目录文件（任意顺序，内部会排序）
/// @param secondary 副目录文件
/// @param isCancelled 返回 YES 时中止并返回 FMErrorCancelled
- (nullable FMDedupResult *)dedupPrimary:(NSArray<FMFileRecord *> *)primary
                               secondary:(NSArray<FMFileRecord *> *)secondary
                                  hasher:(FMFileHasher *)hasher
                                progress:(nullable FMProgressReporter *)progress
                               cancelled:(nullable BOOL (^)(void))isCancelled
                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import "FMModels.h"

NS_ASSUME_NONNULL_BEGIN

/// 文件哈希器（三级去重的哈希支撑层）：
/// - headHash：前 64KB 的 SHA256（预筛）
/// - fullHash：全量分块流式 SHA256（兜底）
/// - 结果按路径跨阶段缓存（同一运行内同一文件不重复计算；跨运行不持久化）
@interface FMFileHasher : NSObject

/// 头部哈希（前 64KB；文件不足 64KB 时为全量）
- (nullable NSData *)headHashForFile:(FMFileRecord *)file error:(NSError **)error;
/// 全量哈希（256KB 分块流式计算）
- (nullable NSData *)fullHashForFile:(FMFileRecord *)file error:(NSError **)error;

/// 实际执行头部哈希计算的次数（供缓存命中测试）
@property (nonatomic, readonly) NSUInteger headHashComputations;
/// 实际执行全量哈希计算的次数（供缓存命中测试）
@property (nonatomic, readonly) NSUInteger fullHashComputations;

/// 常量：头部哈希窗口大小
FOUNDATION_EXPORT const NSUInteger FMHeadHashWindowSize;

@end

NS_ASSUME_NONNULL_END

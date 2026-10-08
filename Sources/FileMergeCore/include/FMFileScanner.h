#import <Foundation/Foundation.h>
#import "FMModels.h"

NS_ASSUME_NONNULL_BEGIN

/// 扫描结果
@interface FMScanResult : NSObject
/// 全部普通文件（按相对路径 Unicode 升序）
@property (nonatomic, readonly, copy) NSArray<FMFileRecord *> *files;
@property (nonatomic, readonly) NSUInteger fileCount;
@property (nonatomic, readonly) unsigned long long totalBytes;
/// 非致命警告（如不可读子目录被跳过）
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;
@end

/// 并行目录扫描器
@interface FMFileScanner : NSObject

/// 深度扫描 rootPath 下所有普通文件。
/// - 根目录不存在/不是目录/不可读 → 返回 FMErrorRootUnreadable（不静默返回空结果）
/// - 子目录不可读 → 记入 warnings 并继续
/// - 符号链接（文件或目录）不作为普通文件收集
/// - isCancelled 返回 YES 时尽快中止并返回 FMErrorCancelled
- (nullable FMScanResult *)scanRoot:(NSString *)rootPath
                             origin:(FMFileOrigin)origin
                         cancelled:(nullable BOOL (^)(void))isCancelled
                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

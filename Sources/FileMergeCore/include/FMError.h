#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FMErrorDomain;

typedef NS_ERROR_ENUM(FMErrorDomain, FMErrorCode) {
    FMErrorCancelled        = 1,  // 操作被用户取消
    FMErrorRootUnreadable   = 2,  // 根目录不可读（避免静默空合并）
    FMErrorInvalidRoot      = 3,  // 根目录不存在或不是目录
    FMErrorValidationFailed = 4,  // 安全校验未通过（路径冲突/别名等）
    FMErrorTargetIsDirectory= 5,  // 覆盖目标为目录，拒绝执行
    FMErrorHashFailed       = 6,  // 哈希计算失败
    FMErrorCopyFailed       = 7,  // 复制失败
};

NS_ASSUME_NONNULL_END

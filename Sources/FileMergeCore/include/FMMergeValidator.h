#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 路径安全校验（合并前的防护网）：
/// - 主/副目录必须存在且为目录；最终目录可以不存在（合并时创建）
/// - 使用 Darwin.realpath 解析最长存在祖先（macOS 26+ 上 URL.resolvingSymlinksInPath 不生效）
/// - 以下情形拒绝执行并返回 FMErrorValidationFailed：
///   1) 三个目录经 realpath 解析后相同（含符号链接别名）
///   2) 任意两者互为祖先/后代
///   3) 大小写折叠比较下的别名（大小写不敏感文件系统防自我覆盖）
@interface FMMergeValidator : NSObject

/// 校验通过返回 nil，否则返回携带原因的 NSError。
+ (nullable NSError *)validatePrimary:(NSString *)primary
                            secondary:(NSString *)secondary
                                 final:(NSString *)finalRoot;

/// 解析路径：对最长存在的祖先取 realpath，再拼回剩余尾部组件（供测试与调试）
+ (NSString *)resolvedPathForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END

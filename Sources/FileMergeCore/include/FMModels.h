#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 文件来源
typedef NS_ENUM(NSInteger, FMFileOrigin) {
    FMFileOriginPrimary   = 0,  // 主目录
    FMFileOriginSecondary = 1,  // 副目录
};

/// 单个文件记录
@interface FMFileRecord : NSObject
@property (nonatomic, readonly) FMFileOrigin origin;
/// 所属根目录（主/副目录路径）
@property (nonatomic, readonly, copy) NSString *rootPath;
/// 相对根目录的路径（POSIX 风格，不含根目录名）
@property (nonatomic, readonly, copy) NSString *relativePath;
/// 绝对路径
@property (nonatomic, readonly, copy) NSString *absolutePath;
/// 文件大小（字节）
@property (nonatomic, readonly) unsigned long long fileSize;

+ (instancetype)recordWithOrigin:(FMFileOrigin)origin
                        rootPath:(NSString *)rootPath
                    relativePath:(NSString *)relativePath
                    absolutePath:(NSString *)absolutePath
                        fileSize:(unsigned long long)fileSize;
@end

/// 目录统计（文件数 + 总字节数）
@interface FMAnalysisStats : NSObject
@property (nonatomic, readonly) NSUInteger fileCount;
@property (nonatomic, readonly) unsigned long long totalBytes;
+ (instancetype)statsWithCount:(NSUInteger)fileCount bytes:(unsigned long long)totalBytes;
@end

/// 分析结果（排重完成后供界面展示与合并使用）
@interface FMAnalysisResult : NSObject
/// 排重后主目录唯一文件（按相对路径 Unicode 升序）
@property (nonatomic, readonly, copy) NSArray<FMFileRecord *> *uniquePrimary;
/// 排重后副目录唯一文件（按相对路径 Unicode 升序）
@property (nonatomic, readonly, copy) NSArray<FMFileRecord *> *uniqueSecondary;
/// 主目录原始统计
@property (nonatomic, readonly, strong) FMAnalysisStats *primaryStats;
/// 副目录原始统计
@property (nonatomic, readonly, strong) FMAnalysisStats *secondaryStats;
/// 预估合并后最终目录统计（全局唯一文件数与字节数）
@property (nonatomic, readonly, strong) FMAnalysisStats *estimatedStats;
/// 被剔除的重复文件总数
@property (nonatomic, readonly) NSUInteger duplicateCount;

- (instancetype)initWithUniquePrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                      uniqueSecondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                         primaryStats:(FMAnalysisStats *)primaryStats
                      secondaryStats:(FMAnalysisStats *)secondaryStats
                       estimatedStats:(FMAnalysisStats *)estimatedStats
                       duplicateCount:(NSUInteger)duplicateCount;
@end

/// 排重结果
@interface FMDedupResult : NSObject
@property (nonatomic, readonly, copy) NSArray<FMFileRecord *> *uniquePrimary;
@property (nonatomic, readonly, copy) NSArray<FMFileRecord *> *uniqueSecondary;
@property (nonatomic, readonly) NSUInteger duplicateCount;
/// 处理过程中被排除的文件告警（如哈希失败），最多 50 条 + 汇总行
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;

- (instancetype)initWithUniquePrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                      uniqueSecondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                       duplicateCount:(NSUInteger)duplicateCount
                             warnings:(nullable NSArray<NSString *> *)warnings;
@end

NS_ASSUME_NONNULL_END

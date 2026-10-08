#import "FMModels.h"

#pragma mark - FMFileRecord

@interface FMFileRecord ()
@end

@implementation FMFileRecord {
    FMFileOrigin _origin;
    NSString *_rootPath;
    NSString *_relativePath;
    NSString *_absolutePath;
    unsigned long long _fileSize;
}

+ (instancetype)recordWithOrigin:(FMFileOrigin)origin
                        rootPath:(NSString *)rootPath
                    relativePath:(NSString *)relativePath
                    absolutePath:(NSString *)absolutePath
                        fileSize:(unsigned long long)fileSize {
    return [[self alloc] initWithOrigin:origin rootPath:rootPath relativePath:relativePath absolutePath:absolutePath fileSize:fileSize];
}

- (instancetype)initWithOrigin:(FMFileOrigin)origin
                      rootPath:(NSString *)rootPath
                  relativePath:(NSString *)relativePath
                  absolutePath:(NSString *)absolutePath
                      fileSize:(unsigned long long)fileSize {
    self = [super init];
    if (self) {
        _origin = origin;
        _rootPath = [rootPath copy];
        _relativePath = [relativePath copy];
        _absolutePath = [absolutePath copy];
        _fileSize = fileSize;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ (%llu bytes)>", _relativePath, _origin == FMFileOriginPrimary ? @"主" : @"副", _fileSize];
}

@end

#pragma mark - FMAnalysisStats

@implementation FMAnalysisStats {
    NSUInteger _fileCount;
    unsigned long long _totalBytes;
}

+ (instancetype)statsWithCount:(NSUInteger)fileCount bytes:(unsigned long long)totalBytes {
    return [[self alloc] initWithCount:fileCount bytes:totalBytes];
}

- (instancetype)initWithCount:(NSUInteger)fileCount bytes:(unsigned long long)totalBytes {
    self = [super init];
    if (self) {
        _fileCount = fileCount;
        _totalBytes = totalBytes;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%lu 个文件 / %llu 字节>", (unsigned long)_fileCount, _totalBytes];
}

@end

#pragma mark - FMAnalysisResult

@implementation FMAnalysisResult {
    NSArray<FMFileRecord *> *_uniquePrimary;
    NSArray<FMFileRecord *> *_uniqueSecondary;
    FMAnalysisStats *_primaryStats;
    FMAnalysisStats *_secondaryStats;
    FMAnalysisStats *_estimatedStats;
    NSUInteger _duplicateCount;
}

- (instancetype)initWithUniquePrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                      uniqueSecondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                         primaryStats:(FMAnalysisStats *)primaryStats
                      secondaryStats:(FMAnalysisStats *)secondaryStats
                       estimatedStats:(FMAnalysisStats *)estimatedStats
                       duplicateCount:(NSUInteger)duplicateCount {
    self = [super init];
    if (self) {
        _uniquePrimary = [uniquePrimary copy] ?: @[];
        _uniqueSecondary = [uniqueSecondary copy] ?: @[];
        _primaryStats = primaryStats;
        _secondaryStats = secondaryStats;
        _estimatedStats = estimatedStats;
        _duplicateCount = duplicateCount;
    }
    return self;
}

@end

#pragma mark - FMDedupResult

@implementation FMDedupResult {
    NSArray<FMFileRecord *> *_uniquePrimary;
    NSArray<FMFileRecord *> *_uniqueSecondary;
    NSUInteger _duplicateCount;
    NSArray<NSString *> *_warnings;
}

- (instancetype)initWithUniquePrimary:(NSArray<FMFileRecord *> *)uniquePrimary
                      uniqueSecondary:(NSArray<FMFileRecord *> *)uniqueSecondary
                       duplicateCount:(NSUInteger)duplicateCount
                             warnings:(NSArray<NSString *> *)warnings {
    self = [super init];
    if (self) {
        _uniquePrimary = [uniquePrimary copy] ?: @[];
        _uniqueSecondary = [uniqueSecondary copy] ?: @[];
        _duplicateCount = duplicateCount;
        _warnings = [warnings copy] ?: @[];
    }
    return self;
}

@end

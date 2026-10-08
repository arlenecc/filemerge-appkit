#import "FMMergeValidator.h"
#import "FMError.h"
#import <limits.h>
#import <unistd.h>

#pragma mark - 路径解析

static BOOL FMPathExists(NSString *path, BOOL *isDir) {
    BOOL dir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
    if (isDir) *isDir = dir;
    return exists;
}

@interface FMMergeValidator ()
@end

@implementation FMMergeValidator

/// 解析路径：对最长存在的祖先取 realpath，再拼回剩余尾部组件。
/// （macOS 26+ 上 URL.resolvingSymlinksInPath 不解析符号链接，必须用 Darwin realpath）
+ (NSString *)resolvedPathForPath:(NSString *)path {
    if (path.length == 0) return path;

    NSString *standardized = [path stringByStandardizingPath];

    // 自底向上找到最长存在祖先，途中收集尾部组件
    NSString *existing = standardized;
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    while (existing.length > 1 && !FMPathExists(existing, NULL)) {
        NSString *parent = [existing stringByDeletingLastPathComponent];
        if ([parent isEqualToString:existing]) break;  // 到达根
        [tail insertObject:[existing lastPathComponent] atIndex:0];
        existing = parent;
    }

    char buf[PATH_MAX];
    if (realpath(existing.fileSystemRepresentation, buf) == NULL) {
        return standardized;  // 解析失败时退回标准化路径
    }
    NSString *resolved = [NSString stringWithUTF8String:buf];
    if (tail.count > 0) {
        resolved = [NSString pathWithComponents:[@[ resolved ] arrayByAddingObjectsFromArray:tail]];
    }
    return resolved;
}

#pragma mark - 校验

+ (nullable NSError *)validatePrimary:(NSString *)primary
                            secondary:(NSString *)secondary
                                 final:(NSString *)finalRoot {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) 主/副目录必须存在且为目录
    BOOL pIsDir = NO, sIsDir = NO, fIsDir = NO;
    if (![fm fileExistsAtPath:primary isDirectory:&pIsDir] || !pIsDir) {
        return [FMMergeValidator errorWithMessage:[NSString stringWithFormat:@"主目录不存在或不是目录: %@", primary]];
    }
    if (![fm fileExistsAtPath:secondary isDirectory:&sIsDir] || !sIsDir) {
        return [FMMergeValidator errorWithMessage:[NSString stringWithFormat:@"副目录不存在或不是目录: %@", secondary]];
    }
    if (![fm isReadableFileAtPath:primary]) {
        return [FMMergeValidator errorWithMessage:[NSString stringWithFormat:@"主目录不可读: %@", primary]];
    }
    if (![fm isReadableFileAtPath:secondary]) {
        return [FMMergeValidator errorWithMessage:[NSString stringWithFormat:@"副目录不可读: %@", secondary]];
    }

    // 2) 最终目录可以是文件吗？不行（允许不存在，合并时创建）
    BOOL finalExists = [fm fileExistsAtPath:finalRoot isDirectory:&fIsDir];
    if (finalExists && !fIsDir) {
        return [FMMergeValidator errorWithMessage:[NSString stringWithFormat:@"最终目录路径已是普通文件: %@", finalRoot]];
    }

    // 3) realpath 解析（含符号链接别名 + 最长存在祖先），再做大小写折叠比较
    NSString *rp = [FMMergeValidator resolvedPathForPath:primary];
    NSString *rs = [FMMergeValidator resolvedPathForPath:secondary];
    NSString *rf = [FMMergeValidator resolvedPathForPath:finalRoot];

    NSArray<NSString *> *names = @[ @"主目录", @"副目录", @"最终目录" ];
    NSArray<NSString *> *paths = @[ rp, rs, rf ];

    for (NSUInteger i = 0; i < paths.count; i++) {
        for (NSUInteger j = i + 1; j < paths.count; j++) {
            if ([FMMergeValidator sameResolvedPath:paths[i] path2:paths[j]]) {
                return [FMMergeValidator errorWithMessage:
                        [NSString stringWithFormat:@"%@与%@解析为同一路径（含符号链接/大小写别名）: %@",
                         names[i], names[j], paths[i]]];
            }
            if ([FMMergeValidator isAncestor:paths[i] of:paths[j]] || [FMMergeValidator isAncestor:paths[j] of:paths[i]]) {
                return [FMMergeValidator errorWithMessage:
                        [NSString stringWithFormat:@"%@与%@互为祖先/后代，拒绝合并: %@ ↔ %@",
                         names[i], names[j], paths[i], paths[j]]];
            }
        }
    }

    return nil;
}

/// 大小写折叠比较（大小写不敏感文件系统防自我覆盖）
+ (BOOL)sameResolvedPath:(NSString *)path1 path2:(NSString *)path2 {
    return [path1 compare:path2 options:NSCaseInsensitiveSearch] == NSOrderedSame;
}

/// 判断 ancestor 是否为 path 的路径边界祖先
+ (BOOL)isAncestor:(NSString *)ancestor of:(NSString *)path {
    if (ancestor.length == 0 || path.length == 0) return NO;
    if ([self sameResolvedPath:ancestor path2:path]) return NO;  // 相等不视为祖先

    NSString *a = [ancestor hasSuffix:@"/"] ? ancestor : [ancestor stringByAppendingString:@"/"];
    // 注意：compare:options: 的 NSAnchoredSearch 不是前缀匹配（返回 Descending），
    // 必须用 rangeOfString:options: 的锚定搜索语义（location == 0）
    NSRange r = [path rangeOfString:a options:(NSCaseInsensitiveSearch | NSAnchoredSearch)];
    return r.location == 0;
}

+ (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:FMErrorDomain code:FMErrorValidationFailed
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@end

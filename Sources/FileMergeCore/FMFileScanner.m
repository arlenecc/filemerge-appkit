#import "FMFileScanner.h"
#import "FMError.h"
#import <limits.h>

#pragma mark - FMScanResult

@interface FMScanResult ()
@end

@implementation FMScanResult {
    NSArray<FMFileRecord *> *_files;
    unsigned long long _totalBytes;
    NSArray<NSString *> *_warnings;
}

- (instancetype)initWithFiles:(NSArray<FMFileRecord *> *)files totalBytes:(unsigned long long)totalBytes warnings:(NSArray<NSString *> *)warnings {
    self = [super init];
    if (self) {
        _files = [files copy] ?: @[];
        _totalBytes = totalBytes;
        _warnings = [warnings copy] ?: @[];
    }
    return self;
}

- (NSUInteger)fileCount {
    return _files.count;
}

- (unsigned long long)totalBytes {
    return _totalBytes;
}

@end

#pragma mark - FMFileScanner

@interface FMFileScanner ()
@end

@implementation FMFileScanner

+ (void)fillError:(NSError **)error code:(FMErrorCode)code message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:FMErrorDomain code:code
                              userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
    }
}

- (nullable FMScanResult *)scanRoot:(NSString *)rootPath
                             origin:(FMFileOrigin)origin
                         cancelled:(nullable BOOL (^)(void))isCancelled
                             error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (isCancelled && isCancelled()) {
        [FMFileScanner fillError:error code:FMErrorCancelled message:@"扫描已取消"];
        return nil;
    }

    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:rootPath isDirectory:&isDir];
    if (!exists || !isDir) {
        [FMFileScanner fillError:error code:FMErrorInvalidRoot
                         message:[NSString stringWithFormat:@"根目录不存在或不是目录: %@", rootPath]];
        return nil;
    }
    if (![fm isReadableFileAtPath:rootPath]) {
        [FMFileScanner fillError:error code:FMErrorRootUnreadable
                         message:[NSString stringWithFormat:@"根目录不可读: %@", rootPath]];
        return nil;
    }

    // 归一化根路径：先 realpath 解析，再去掉末尾斜杠。
    // 必须与枚举器输出的路径表示对齐——NSFileManager 枚举 /tmp、/var 等符号链接
    // 目录时返回其真实路径（/private/tmp、/private/var），若根路径保持短表示，
    // 相对路径前缀剥离会静默失败，把绝对路径误当作相对路径（合并将写错位置）。
    // 根目录此时已验证存在，realpath 必定成功；失败则按不可读处理。
    char resolvedBuf[PATH_MAX];
    NSString *normalizedRoot;
    if (realpath(rootPath.fileSystemRepresentation, resolvedBuf)) {
        normalizedRoot = [fm stringWithFileSystemRepresentation:resolvedBuf
                                                         length:strlen(resolvedBuf)];
    } else {
        [FMFileScanner fillError:error code:FMErrorRootUnreadable
                         message:[NSString stringWithFormat:@"无法解析根目录真实路径: %@", rootPath]];
        return nil;
    }
    while ([normalizedRoot hasSuffix:@"/"] && normalizedRoot.length > 1) {
        normalizedRoot = [normalizedRoot substringToIndex:normalizedRoot.length - 1];
    }

    NSMutableArray<FMFileRecord *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    __block unsigned long long totalBytes = 0;
    // 警告封顶：不可读条目极多时避免警告数组与日志洪泛
    static const NSUInteger FMMaxWarnings = 50;
    __block NSUInteger skippedCount = 0;

    NSURL *rootURL = [NSURL fileURLWithPath:rootPath];
    NSArray<NSURLResourceKey> *keys = @[ NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey ];

    NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:rootURL
                                          includingPropertiesForKeys:keys
                                                             options:0
                                                        errorHandler:^BOOL(NSURL *url, NSError *err) {
        // 子目录不可读等错误：记录警告并继续
        skippedCount++;
        if (warnings.count < FMMaxWarnings) {
            [warnings addObject:[NSString stringWithFormat:@"跳过不可读条目: %@ (%@)",
                                 [url path], err.localizedDescription ?: @""]];
        }
        return YES;
    }];

    if (!enumerator) {
        [FMFileScanner fillError:error code:FMErrorRootUnreadable
                         message:[NSString stringWithFormat:@"无法枚举根目录: %@", rootPath]];
        return nil;
    }

    // 前缀拼接移出循环；根为 "/" 时前缀本身就是 "/"（避免拼成 "//"）
    NSString *rootPrefix = [normalizedRoot isEqualToString:@"/"]
        ? @"/" : [normalizedRoot stringByAppendingString:@"/"];

    for (NSURL *url in enumerator) {
        if (isCancelled && isCancelled()) {
            [FMFileScanner fillError:error code:FMErrorCancelled message:@"扫描已取消"];
            return nil;
        }

        NSError *resErr = nil;
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:&resErr];
        if (!values) continue;

        BOOL isSymlink = [values[NSURLIsSymbolicLinkKey] boolValue];
        BOOL isRegular = [values[NSURLIsRegularFileKey] boolValue];
        if (isSymlink || !isRegular) continue;

        NSString *absolutePath = [url path];
        // 严格前缀剥离：必须是 "root/" 开头才剥离（避免 "/a/b" 误匹配 "/a/bc"）；
        // 不匹配视为内部错误而非静默降级——绝对路径绝不能当作相对路径参与合并
        NSString *relativePath;
        if ([absolutePath hasPrefix:rootPrefix]) {
            relativePath = [absolutePath substringFromIndex:rootPrefix.length];
        } else if ([absolutePath isEqualToString:normalizedRoot]) {
            continue;  // 根目录自身（不可能是普通文件，防御性跳过）
        } else {
            [FMFileScanner fillError:error code:FMErrorInvalidRoot
                             message:[NSString stringWithFormat:
                                      @"根路径与文件路径表示不一致: root=%@ file=%@", normalizedRoot, absolutePath]];
            return nil;
        }
        if (relativePath.length == 0) continue;

        unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
        totalBytes += size;

        [files addObject:[FMFileRecord recordWithOrigin:origin
                                               rootPath:rootPath
                                           relativePath:relativePath
                                           absolutePath:absolutePath
                                               fileSize:size]];
    }

    // 超出封顶的不可读条目以汇总行提示
    if (skippedCount > warnings.count) {
        [warnings addObject:[NSString stringWithFormat:@"……另有 %lu 个不可读条目未逐条列出",
                             (unsigned long)(skippedCount - warnings.count)]];
    }

    // 相对路径 Unicode 升序，保证排重与合并决策可复现
    [files sortUsingComparator:^NSComparisonResult(FMFileRecord *a, FMFileRecord *b) {
        return [a.relativePath compare:b.relativePath];
    }];

    return [[FMScanResult alloc] initWithFiles:files totalBytes:totalBytes warnings:warnings];
}

@end

#import "FMFileHasher.h"
#import "FMError.h"
#import <CommonCrypto/CommonCrypto.h>

const NSUInteger FMHeadHashWindowSize = 65536;

#pragma mark - 私有缓存条目

@interface FMHashCacheEntry : NSObject
@property (nonatomic, strong) NSData *headHash;
@property (nonatomic, strong) NSData *fullHash;
@end

@implementation FMHashCacheEntry
@end

#pragma mark - FMFileHasher

@interface FMFileHasher ()
@end

@implementation FMFileHasher {
    NSLock *_lock;
    NSMutableDictionary<NSString *, FMHashCacheEntry *> *_cache;  // key: absolutePath
    NSUInteger _headComputations;
    NSUInteger _fullComputations;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _cache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (NSUInteger)headHashComputations {
    [_lock lock];
    NSUInteger v = _headComputations;
    [_lock unlock];
    return v;
}

- (NSUInteger)fullHashComputations {
    [_lock lock];
    NSUInteger v = _fullComputations;
    [_lock unlock];
    return v;
}

- (nullable NSData *)headHashForFile:(FMFileRecord *)file error:(NSError **)error {
    if (file == nil) {
        [FMFileHasher fillError:error code:FMErrorHashFailed message:@"文件记录为空"];
        return nil;
    }
    FMHashCacheEntry *entry = [self entryForFile:file];
    [_lock lock];
    NSData *cached = entry.headHash;
    [_lock unlock];
    if (cached) return cached;

    NSData *hash = [FMFileHasher hashPath:file.absolutePath byteLimit:FMHeadHashWindowSize error:error];
    if (!hash) return nil;

    [_lock lock];
    entry.headHash = hash;
    _headComputations++;
    [_lock unlock];
    return hash;
}

- (nullable NSData *)fullHashForFile:(FMFileRecord *)file error:(NSError **)error {
    if (file == nil) {
        [FMFileHasher fillError:error code:FMErrorHashFailed message:@"文件记录为空"];
        return nil;
    }
    FMHashCacheEntry *entry = [self entryForFile:file];
    [_lock lock];
    NSData *cached = entry.fullHash;
    [_lock unlock];
    if (cached) return cached;

    NSData *hash = [FMFileHasher hashPath:file.absolutePath byteLimit:0 error:error];
    if (!hash) return nil;

    [_lock lock];
    entry.fullHash = hash;
    _fullComputations++;
    [_lock unlock];
    return hash;
}

- (FMHashCacheEntry *)entryForFile:(FMFileRecord *)file {
    [_lock lock];
    FMHashCacheEntry *entry = _cache[file.absolutePath];
    if (!entry) {
        entry = [[FMHashCacheEntry alloc] init];
        _cache[file.absolutePath] = entry;
    }
    [_lock unlock];
    return entry;
}

/// 分块流式 SHA256；byteLimit > 0 时只读前 byteLimit 字节（头部哈希）
+ (nullable NSData *)hashPath:(NSString *)path byteLimit:(NSUInteger)byteLimit error:(NSError **)error {
    FILE *fp = fopen(path.fileSystemRepresentation, "rb");
    if (!fp) {
        [FMFileHasher fillError:error code:FMErrorHashFailed
                  message:[NSString stringWithFormat:@"无法读取文件: %@", path]];
        return nil;
    }

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    const size_t chunkSize = 256 * 1024;
    uint8_t *buffer = malloc(chunkSize);
    size_t remaining = byteLimit;
    size_t n;
    BOOL ok = YES;
    while ((n = fread(buffer, 1, (byteLimit > 0 && remaining < chunkSize) ? remaining : chunkSize, fp)) > 0) {
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
        if (byteLimit > 0) {
            remaining -= n;
            if (remaining == 0) break;
        }
    }
    if (ferror(fp)) ok = NO;
    free(buffer);
    fclose(fp);

    if (!ok) {
        [FMFileHasher fillError:error code:FMErrorHashFailed
                  message:[NSString stringWithFormat:@"读取文件失败: %@", path]];
        return nil;
    }

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

+ (void)fillError:(NSError **)error code:(FMErrorCode)code message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:FMErrorDomain code:code
                              userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
    }
}

@end

#import "FMProgressReporter.h"
#import <mach/mach_time.h>

@interface FMProgressReporter ()
@end

@implementation FMProgressReporter {
    NSLock *_lock;
    FMProgressHandler _handler;
    NSTimeInterval _interval;
    NSUInteger _completed;
    NSUInteger _total;
    double _lastEmittedFraction;
    NSTimeInterval _lastEmitTime;
    BOOL _finished;
}

- (instancetype)initWithInterval:(NSTimeInterval)interval handler:(FMProgressHandler)handler {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _handler = [handler copy];
        _interval = interval > 0 ? interval : 0;
        _lastEmitTime = 0;
    }
    return self;
}

- (void)expandTotalBy:(NSUInteger)delta {
    if (delta == 0) return;
    [_lock lock];
    _total += delta;
    [_lock unlock];
    [self emitIfDueForced:NO];
}

- (void)incrementCompleted {
    [_lock lock];
    _completed++;
    [_lock unlock];
    [self emitIfDueForced:NO];
}

- (void)finish {
    [_lock lock];
    _finished = YES;
    if (_total > 0) {
        _completed = _total;  // 收敛到满格
    }
    [_lock unlock];
    [self emitIfDueForced:YES];
}

- (double)currentFraction {
    [_lock lock];
    double fraction = [self rawFractionLocked];
    [_lock unlock];
    return fraction;
}

// 内部：原始比例（total==0 时为 0；finish 后恒为 1）
- (double)rawFractionLocked {
    if (_finished) return 1.0;
    if (_total == 0) return 0.0;
    double fraction = (double)_completed / (double)_total;
    return fraction > 1.0 ? 1.0 : fraction;
}

- (void)emitIfDueForced:(BOOL)force {
    if (!_handler) return;

    double fraction;
    NSUInteger completed, total;
    BOOL shouldEmit = NO;
    NSTimeInterval now = [self monotonicNow];

    [_lock lock];
    if (_finished) {
        fraction = 1.0;
        completed = _total;
        total = _total;
        shouldEmit = force || _lastEmittedFraction < 1.0;
    } else {
        double raw = [self rawFractionLocked];
        // 钳制：总量扩展导致的回落不外发，保证对外进度单调不减
        fraction = raw > _lastEmittedFraction ? raw : _lastEmittedFraction;
        completed = _completed;
        total = _total;
        if (force) {
            shouldEmit = YES;
        } else if (_interval <= 0) {
            shouldEmit = YES;
        } else {
            shouldEmit = (now - _lastEmitTime) >= _interval;
        }
    }
    if (shouldEmit) {
        _lastEmittedFraction = fraction;
        _lastEmitTime = now;
    }
    [_lock unlock];

    if (shouldEmit) {
        _handler(fraction, completed, total);
    }
}

- (NSTimeInterval)monotonicNow {
    static mach_timebase_info_data_t base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&base); });
    uint64_t t = mach_absolute_time();
    return (NSTimeInterval)t * base.numer / base.denom / 1e9;
}

@end

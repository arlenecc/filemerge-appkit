#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 进度回调：fraction ∈ [0,1]，completed/total 为工作量单元
typedef void (^FMProgressHandler)(double fraction, NSUInteger completed, NSUInteger total);

/// 线程安全的进度上报器：
/// - 总量初始为 0，随阶段发现通过 expandTotalBy: 扩展（只增不减）
/// - 回调按 interval 节流（默认 100ms），避免海量小更新形成回调风暴
/// - fraction 单调不减（总量扩展导致的回落会被钳制，进度条不回跳）
/// - finish 强制收敛到 100%
@interface FMProgressReporter : NSObject

- (instancetype)initWithInterval:(NSTimeInterval)interval handler:(FMProgressHandler)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 扩展总量（只增不减）
- (void)expandTotalBy:(NSUInteger)delta;
/// 完成一个工作量单元
- (void)incrementCompleted;
/// 强制发出最终进度（completed==total，fraction==1，若 total==0 则也视为 1）
- (void)finish;

/// 当前快照（线程安全）
- (double)currentFraction;

@end

NS_ASSUME_NONNULL_END

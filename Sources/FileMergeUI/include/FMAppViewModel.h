#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FMAnalysisResult;
@class FMAppViewModel;

/// 应用状态
typedef NS_ENUM(NSInteger, FMAppState) {
    FMAppStateIdle     = 0,  // 空闲（可选取目录/开始分析）
    FMAppStateAnalyzing= 1,  // 分析中（扫描+排重）
    FMAppStateAnalyzed = 2,  // 分析完成（可开始合并）
    FMAppStateMerging  = 3,  // 合并中
};

@protocol FMAppViewModelDelegate <NSObject>
/// 状态/统计/按钮可用性等发生变化（在 callbackQueue 上回调）
- (void)viewModelDidChange:(FMAppViewModel *)viewModel;
/// 新增一行日志（在 callbackQueue 上回调）
- (void)viewModel:(FMAppViewModel *)viewModel didAppendLogLine:(NSString *)line;
@end

/// 界面状态机：驱动 AppKit 界面，自身不含界面代码（可单元测试）
@interface FMAppViewModel : NSObject

@property (nonatomic, weak, nullable) id<FMAppViewModelDelegate> delegate;
/// 回调队列，默认主队列；测试可注入私有串行队列
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue;

@property (nonatomic, copy, nullable) NSString *primaryPath;
@property (nonatomic, copy, nullable) NSString *secondaryPath;
@property (nonatomic, copy, nullable) NSString *finalPath;

@property (nonatomic, readonly) FMAppState state;
@property (nonatomic, readonly, nullable) FMAnalysisResult *result;
/// 当前总体进度 0..1（每次分析/合并开始时归零）
@property (nonatomic, readonly) double progress;
/// 当前阶段描述（如 "正在扫描主目录…"）
@property (nonatomic, readonly, copy) NSString *phaseText;

/// 目录选择按钮：空闲或已分析时可用（已分析状态下更换目录会使结果失效）
@property (nonatomic, readonly) BOOL canPickDirectories;
/// 开始分析按钮：(空闲或已分析) 且三个路径均非空
@property (nonatomic, readonly) BOOL canStartAnalysis;
/// 开始合并按钮：仅"已分析"状态可用
@property (nonatomic, readonly) BOOL canStartMerge;

- (void)startAnalysis;
- (void)startMerge;
/// 使当前分析结果失效并回到空闲（已分析状态下更换目录时调用；其余状态为无操作）
- (void)resetAnalysis;
/// 请求取消当前分析/合并（忙碌时生效；空闲时无操作）。
/// 引擎在文件粒度检查取消标志，当前文件处理完成后尽快回到空闲。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 主界面控制器（AppKit，手动约束布局）：
/// - 上 1/3：配置区（主目录/副目录/最终目录 + 开始分析）
/// - 下 2/3：处理过程显示区（顶部统计条 + 最右"开始合并"按钮，中部日志，底部状态栏进度）
@interface FMMainViewController : NSViewController

@end

NS_ASSUME_NONNULL_END

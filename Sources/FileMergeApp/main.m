#import <AppKit/AppKit.h>
#import "FMMainViewController.h"

#pragma mark - 应用委托

@interface FMAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation FMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 620)
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"文件去重合并工具";
    self.window.minSize = NSMakeSize(760, 500);
    self.window.contentViewController = [[FMMainViewController alloc] init];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    // 仅在未激活时激活，避免对已激活应用重复 activate 导致目录面板被取消（macOS 26+）
    if (![NSApp isActive]) {
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}

+ (NSMenu *)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // 应用菜单
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"关于 文件去重合并工具"
                                                action:@selector(orderFrontStandardAboutPanel:)
                                         keyEquivalent:@""]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 文件去重合并工具"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [appMenu addItem:quit];
    appItem.submenu = appMenu;

    // 文件菜单
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"文件" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"关闭窗口"
                                                 action:@selector(performClose:)
                                          keyEquivalent:@"w"]];
    fileItem.submenu = fileMenu;

    // 编辑菜单
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"]];
    editItem.submenu = editMenu;

    // 窗口菜单
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"窗口" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"最小化"
                                                   action:@selector(performMiniaturize:)
                                            keyEquivalent:@"m"]];
    [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"缩放" action:@selector(performZoom:) keyEquivalent:@""]];
    windowItem.submenu = windowMenu;

    return mainMenu;
}

@end

#pragma mark - 入口

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        FMAppDelegate *delegate = [[FMAppDelegate alloc] init];
        app.delegate = delegate;
        app.mainMenu = [FMAppDelegate buildMainMenu];

        [app run];
    }
    return 0;
}

#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
// Test-only host: delegates all update discovery, UI, download, installation,
// quit-waiting and relaunch semantics to the official Sparkle framework.
@interface TestHost : NSObject <NSApplicationDelegate, SPUUpdaterDelegate>
@property NSWindow *window;
@property SPUStandardUpdaterController *controller;
@end
@implementation TestHost
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:self userDriverDelegate:nil];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(150,150,460,180) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"PushGo isolated Sparkle path test";
    NSTextField *label = [NSTextField labelWithString:[@"Actual test host version " stringByAppendingString:[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]];
    label.frame = NSMakeRect(20,120,400,25); [self.window.contentView addSubview:label];
    NSButton *check = [NSButton buttonWithTitle:@"Check for Updates" target:self.controller action:@selector(checkForUpdates:)];
    [check bind:NSEnabledBinding toObject:self.controller.updater withKeyPath:@"canCheckForUpdates" options:nil];
    check.frame = NSMakeRect(20,75,200,32); [self.window.contentView addSubview:check];
    NSButton *quit = [NSButton buttonWithTitle:@"Quit Test Host" target:NSApp action:@selector(terminate:)];
    quit.frame = NSMakeRect(240,75,180,32); [self.window.contentView addSubview:quit];
    NSButton *stage = [NSButton buttonWithTitle:@"Stage Update on Quit" target:self action:@selector(stageOnQuit:)];
    [stage bind:NSEnabledBinding toObject:self.controller.updater withKeyPath:@"canCheckForUpdates" options:nil];
    stage.frame = NSMakeRect(20,25,220,32); [self.window.contentView addSubview:stage];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"HOST_READY version=%@ pid=%d path=%@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"], getpid(), NSBundle.mainBundle.bundlePath);
}
- (void)stageOnQuit:(id)sender {
    self.controller.updater.automaticallyDownloadsUpdates = YES;
    [self.controller.updater checkForUpdatesInBackground];
}
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error { NSLog(@"UPDATE_ABORT %@", error); }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error { NSLog(@"UPDATE_CYCLE_END error=%@", error); }
@end
int main(int argc, const char *argv[]) { @autoreleasepool { NSApplication *app = NSApplication.sharedApplication; TestHost *host = [TestHost new]; app.delegate = host; [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run]; } return 0; }

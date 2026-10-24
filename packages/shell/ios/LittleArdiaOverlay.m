#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

typedef uintptr_t CGSConnectionID;
extern CGSConnectionID CGSDefaultConnectionForThread(void);
extern int32_t CGSSetWindowTags(CGSConnectionID cid, NSInteger wid, const uint32_t *tags, int tagSize);
extern int32_t CGSClearWindowTags(CGSConnectionID cid, NSInteger wid, const uint32_t *tags, int tagSize);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern int32_t CGSAddWindowsToSpaces(CGSConnectionID cid, CFArrayRef windowIDs, CFArrayRef spaceIDs);

static NSString *const kSmallWindowIdentifier = @"ardia.window.small";
static NSString *const kSearchTitlePrefix = @"ardia.search";
static const CGFloat kDefaultPaletteHeight = 107.0;
static const CGFloat kMinPaletteHeight = 80.0;
static const CGFloat kMaxPaletteHeight = 520.0;
static const CGFloat kFullWindowWidth = 900.0;
static const CGFloat kFullWindowHeight = 640.0;
static const CGFloat kFullWindowThreshold = 800.0;
static const NSTimeInterval kPaletteAnimationDuration = 0.12;
static const NSTimeInterval kExpansionAnimationDuration = 0.18;

static BOOL IsLittleWindow(NSWindow *w) {
    if (!w) return NO;
    return [w.identifier isEqualToString:kSmallWindowIdentifier];
}

static void TriggerNewLittleArdia(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu *mainMenu = [NSApp mainMenu];
        for (NSMenuItem *top in [mainMenu itemArray]) {
            if ([top hasSubmenu]) {
                for (NSMenuItem *item in [[top submenu] itemArray]) {
                    if ([item.title isEqualToString:@"New Little Ardia Window"]) {
                        [NSApp sendAction:item.action to:item.target from:item];
                        [NSApp activateIgnoringOtherApps:YES];
                        return;
                    }
                }
            }
        }
    });
}

static OSStatus HotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    TriggerNewLittleArdia();
    return noErr;
}

static void InstallGlobalHotkey(void) {
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&HotKeyHandler, 1, &eventType, NULL, NULL);

    EventHotKeyID hotKeyID;
    hotKeyID.signature = 'ArdA';
    hotKeyID.id = 1;
    EventHotKeyRef hotKeyRef;
    RegisterEventHotKey(kVK_ANSI_N, cmdKey | optionKey, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef);
}

@interface LittleArdiaObserver : NSObject
@end

@implementation LittleArdiaObserver
+ (instancetype)shared {
    static LittleArdiaObserver *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[LittleArdiaObserver alloc] init];
    });
    return s;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"title"] && [object isKindOfClass:[NSWindow class]]) {
        NSWindow *win = (NSWindow *)object;
        if (!IsLittleWindow(win)) return;
        
        // Dynamically adjust search palette height to fit suggestions
        if ([win.title hasPrefix:kSearchTitlePrefix]) {
            NSArray *parts = [win.title componentsSeparatedByString:@":"];
            CGFloat targetH = (parts.count > 1) ? [parts[1] doubleValue] : kDefaultPaletteHeight;
            if (targetH < kMinPaletteHeight) targetH = kDefaultPaletteHeight;
            if (targetH > kMaxPaletteHeight) targetH = kMaxPaletteHeight;
            
            if (fabs(win.frame.size.height - targetH) > 2.0 && win.frame.size.width < kFullWindowThreshold) {
                NSRect frame = win.frame;
                CGFloat topY = frame.origin.y + frame.size.height;
                frame.size.height = targetH;
                frame.origin.y = topY - targetH;
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = kPaletteAnimationDuration;
                    context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                    [[win animator] setFrame:frame display:YES];
                } completionHandler:^{
                    [win invalidateShadow];
                }];
                [win invalidateShadow];
            }
            return;
        }
        
        // Expanded to full browser
        NSString *previousTitle = change[NSKeyValueChangeOldKey];
        BOOL wasSearchPalette = ([previousTitle isKindOfClass:[NSString class]] && [previousTitle hasPrefix:kSearchTitlePrefix]) ||
                                (win.frame.size.width < kFullWindowThreshold && ![win.title hasPrefix:kSearchTitlePrefix]);
        if (wasSearchPalette && win.title.length > 0) {
            if (win.frame.size.width < kFullWindowThreshold) {
                NSScreen *screen = win.screen ?: [NSScreen mainScreen];
                NSRect visible = screen.visibleFrame;
                NSSize fullSize = NSMakeSize(kFullWindowWidth, kFullWindowHeight);
                CGFloat lift = MIN(visible.size.height * 0.05, (visible.size.height - fullSize.height) / 2.0);
                NSRect expandedFrame = NSMakeRect(
                    round(NSMidX(visible) - fullSize.width / 2.0),
                    round(NSMidY(visible) - fullSize.height / 2.0 + lift),
                    fullSize.width,
                    fullSize.height
                );
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = kExpansionAnimationDuration;
                    context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                    [[win animator] setFrame:expandedFrame display:YES];
                } completionHandler:^{
                    [win invalidateShadow];
                }];
                [win invalidateShadow];
            }
        }
    }
}
@end

static void ConfigureLittleWindow(NSWindow *win) {
    if (!win) return;
    
    static const char *kConfiguredKey = "kConfiguredKey";
    BOOL alreadyConfigured = [objc_getAssociatedObject(win, kConfiguredKey) boolValue];
    
    if (!alreadyConfigured) {
        objc_setAssociatedObject(win, kConfiguredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 0. Transparent backing & flexible sizing
        win.minSize = NSMakeSize(350, 50);
        win.opaque = NO;
        win.backgroundColor = [NSColor clearColor];
        win.hasShadow = YES;
        
        // 1. Move to active space and allow floating on top of fullscreen spaces
        win.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
        win.level = NSFloatingWindowLevel;
        
        // 2. Set Quartz WindowServer tags: auxiliary overlay tag 0x00400000, clear document tag 0x00000400
        CGSConnectionID cid = CGSDefaultConnectionForThread();
        uint32_t setTags[4] = {0x00400000, 0, 0, 0};
        uint32_t clearTags[4] = {0x00000400, 0, 0, 0};
        CGSSetWindowTags(cid, win.windowNumber, setTags, 32);
        CGSClearWindowTags(cid, win.windowNumber, clearTags, 32);
        
        // 3. Explicitly bind window to the currently active managed space
        CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid);
        if (displays) {
            NSArray *dList = (__bridge NSArray *)displays;
            if (dList.count > 0) {
                NSDictionary *first = dList.firstObject;
                NSDictionary *cur = first[@"Current Space"];
                NSNumber *spaceID = cur[@"ManagedSpaceID"];
                if (spaceID) {
                    NSArray *wids = @[@(win.windowNumber)];
                    NSArray *sids = @[spaceID];
                    CGSAddWindowsToSpaces(cid, (__bridge CFArrayRef)wids, (__bridge CFArrayRef)sids);
                }
            }
            CFRelease(displays);
        }
    }
    
    // 4. Title observation for dynamic suggestion sizing and smooth expansion to 900x640 on URL enter
    static const char *kTitleObsKey = "kTitleObsKey";
    static const char *kCloseObsKey = "kCloseObsKey";
    static const char *kResignObserverKey = "kResignObserverKey";
    if (!objc_getAssociatedObject(win, kTitleObsKey)) {
        [win addObserver:[LittleArdiaObserver shared] forKeyPath:@"title" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
        objc_setAssociatedObject(win, kTitleObsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        id closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                                             object:win
                                                                              queue:[NSOperationQueue mainQueue]
                                                                         usingBlock:^(NSNotification *note) {
            NSWindow *closingWin = (NSWindow *)note.object;
            id closeObs = objc_getAssociatedObject(closingWin, kCloseObsKey);
            if (closeObs) {
                [[NSNotificationCenter defaultCenter] removeObserver:closeObs];
                objc_setAssociatedObject(closingWin, kCloseObsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            id resignObs = objc_getAssociatedObject(closingWin, kResignObserverKey);
            if (resignObs) {
                [[NSNotificationCenter defaultCenter] removeObserver:resignObs];
                objc_setAssociatedObject(closingWin, kResignObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (objc_getAssociatedObject(closingWin, kTitleObsKey)) {
                @try {
                    [closingWin removeObserver:[LittleArdiaObserver shared] forKeyPath:@"title"];
                } @catch (NSException *e) {}
                objc_setAssociatedObject(closingWin, kTitleObsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }];
        objc_setAssociatedObject(win, kCloseObsKey, closeObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // 5. Automatically dismiss search palette on blur
    if (!objc_getAssociatedObject(win, kResignObserverKey)) {
        id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification
                                                                   object:win
                                                                    queue:[NSOperationQueue mainQueue]
                                                               usingBlock:^(NSNotification *note) {
            NSWindow *w = (NSWindow *)note.object;
            if ([w.title hasPrefix:kSearchTitlePrefix]) {
                [w performClose:nil];
            }
        }];
        objc_setAssociatedObject(win, kResignObserverKey, obs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void (*orig_makeKeyAndOrderFront)(id, SEL, id);

static void my_makeKeyAndOrderFront(NSWindow *self, SEL _cmd, id sender) {
    if (IsLittleWindow(self)) {
        ConfigureLittleWindow(self);
    }
    orig_makeKeyAndOrderFront(self, _cmd, sender);
}

static void (*orig_orderFront)(id, SEL, id);

static void my_orderFront(NSWindow *self, SEL _cmd, id sender) {
    if (IsLittleWindow(self)) {
        ConfigureLittleWindow(self);
    }
    orig_orderFront(self, _cmd, sender);
}

__attribute__((constructor))
static void OverlayInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        InstallGlobalHotkey();
    }];
    
    Class winCls = [NSWindow class];
    
    Method mMakeKey = class_getInstanceMethod(winCls, @selector(makeKeyAndOrderFront:));
    if (mMakeKey) {
        orig_makeKeyAndOrderFront = (void (*)(id, SEL, id))method_getImplementation(mMakeKey);
        method_setImplementation(mMakeKey, (IMP)my_makeKeyAndOrderFront);
    }
    
    Method mOrderFront = class_getInstanceMethod(winCls, @selector(orderFront:));
    if (mOrderFront) {
        orig_orderFront = (void (*)(id, SEL, id))method_getImplementation(mOrderFront);
        method_setImplementation(mOrderFront, (IMP)my_orderFront);
    }
    
    Class nativeWinCls = NSClassFromString(@"NativeWidgetMacNSWindow");
    if (nativeWinCls) {
        Method nm = class_getInstanceMethod(nativeWinCls, @selector(makeKeyAndOrderFront:));
        if (nm && method_getImplementation(nm) != method_getImplementation(mMakeKey)) {
            void (*orig_native)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(nm);
            method_setImplementation(nm, imp_implementationWithBlock(^(NSWindow *w, id sender) {
                if (IsLittleWindow(w)) {
                    ConfigureLittleWindow(w);
                }
                orig_native(w, @selector(makeKeyAndOrderFront:), sender);
            }));
        }
    }
}

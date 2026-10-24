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

static BOOL IsLittleWindow(NSWindow *w) {
    if (!w) return NO;
    if ([w.identifier isEqualToString:@"ardia.window.small"]) return YES;
    if (w.level == NSFloatingWindowLevel) return YES;
    NSSize sz = w.frame.size;
    if (sz.width >= 350 && sz.width <= 1050 && sz.height >= 50 && sz.height <= 750) {
        return YES;
    }
    return NO;
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
        if ([win.title hasPrefix:@"ardia.search"]) {
            NSArray *parts = [win.title componentsSeparatedByString:@":"];
            CGFloat targetH = (parts.count > 1) ? [parts[1] doubleValue] : 107.0;
            if (targetH < 80.0) targetH = 107.0;
            if (targetH > 520.0) targetH = 520.0;
            
            if (fabs(win.frame.size.height - targetH) > 2.0 && win.frame.size.width < 800) {
                NSRect frame = win.frame;
                CGFloat topY = frame.origin.y + frame.size.height;
                frame.size.height = targetH;
                frame.origin.y = topY - targetH;
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.12;
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
        if (![win.title hasPrefix:@"ardia.search"] && ![win.title hasSuffix:@"New Tab"] && win.title.length > 0) {
            if (win.frame.size.width < 800) {
                NSScreen *screen = win.screen ?: [NSScreen mainScreen];
                NSRect visible = screen.visibleFrame;
                NSSize fullSize = NSMakeSize(900, 640);
                CGFloat lift = MIN(visible.size.height * 0.05, (visible.size.height - fullSize.height) / 2.0);
                NSRect expandedFrame = NSMakeRect(
                    round(NSMidX(visible) - fullSize.width / 2.0),
                    round(NSMidY(visible) - fullSize.height / 2.0 + lift),
                    fullSize.width,
                    fullSize.height
                );
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.18;
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
    
    // 3. Center on the display where the user currently has their mouse cursor
    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen *targetScreen = nil;
    for (NSScreen *s in [NSScreen screens]) {
        if (NSMouseInRect(mouse, s.frame, NO)) {
            targetScreen = s;
            break;
        }
    }
    if (!targetScreen) targetScreen = [NSScreen mainScreen];
    
    BOOL isSearchPalette = [win.title hasPrefix:@"ardia.search"] || (![win.title length]) || [win.title hasSuffix:@"New Tab"];
    
    if (targetScreen) {
        NSRect visible = targetScreen.visibleFrame;
        NSSize sz = isSearchPalette ? NSMakeSize(680, 107) : NSMakeSize(900, 640);
        CGFloat lift = isSearchPalette
            ? MIN(visible.size.height * 0.16, (visible.size.height - sz.height) / 2.0)
            : MIN(visible.size.height * 0.05, (visible.size.height - sz.height) / 2.0);
        NSRect newFrame = NSMakeRect(
            round(NSMidX(visible) - sz.width / 2.0),
            round(NSMidY(visible) - sz.height / 2.0 + lift),
            sz.width,
            sz.height
        );
        [win setFrame:newFrame display:YES];
    }
    
    // 4. Explicitly bind window to the currently active managed space
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
    
    // 5. Title observation for dynamic suggestion sizing and smooth expansion to 900x640 on URL enter
    static const char *kTitleObsKey = "kTitleObsKey";
    if (!objc_getAssociatedObject(win, kTitleObsKey)) {
        [win addObserver:[LittleArdiaObserver shared] forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:NULL];
        objc_setAssociatedObject(win, kTitleObsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // 6. Automatically dismiss search palette on blur
    static const char *kResignObserverKey = "kResignObserverKey";
    if (!objc_getAssociatedObject(win, kResignObserverKey)) {
        id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification
                                                                   object:win
                                                                    queue:[NSOperationQueue mainQueue]
                                                               usingBlock:^(NSNotification *note) {
            NSWindow *w = (NSWindow *)note.object;
            if ([w.title hasPrefix:@"ardia.search"] || [w.title hasSuffix:@"New Tab"] || w.frame.size.width < 800) {
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

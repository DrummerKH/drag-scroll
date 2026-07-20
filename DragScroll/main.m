#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

#define DEFAULT_BUTTON 5
#define DEFAULT_KEYS kCGEventFlagMaskShift
#define DEFAULT_SPEED 3
#define MAX_KEY_COUNT 5
#define NO_KEYCODE (-1)

#define EQ(x, y) (CFStringCompare(x, y, kCFCompareCaseInsensitive) == kCFCompareEqualTo)

static NSString *const kPrefButton   = @"button";
static NSString *const kPrefKeys     = @"keys";
static NSString *const kPrefSpeed    = @"speed";
static NSString *const kPrefKeyCode   = @"keyCode";
static NSString *const kPrefKeyLabel  = @"keyLabel";
static NSString *const kPrefKeyToggle = @"keyToggle";

static const CFStringRef AX_NOTIFICATION = CFSTR("com.apple.accessibility.api");

// Modifier table shared by preferences <-> UI.
static const CGEventFlags MODIFIER_MASKS[] = {
    kCGEventFlagMaskAlphaShift,
    kCGEventFlagMaskShift,
    kCGEventFlagMaskControl,
    kCGEventFlagMaskAlternate,
    kCGEventFlagMaskCommand,
};
static NSString *const MODIFIER_PREF_NAMES[] = {
    @"capslock", @"shift", @"control", @"option", @"command",
};
static NSString *const MODIFIER_TITLES[] = {
    @"⇪ Caps Lock", @"⇧ Shift", @"⌃ Control", @"⌥ Option", @"⌘ Command",
};
static const int MODIFIER_COUNT = 5;

// ---------------------------------------------------------------------------
// Event-tap state (configured live from preferences)
// ---------------------------------------------------------------------------

static bool TRUSTED;

static int BUTTON;          // configured button number (0 = off, 3..32)
static int BUTTON_COMPARE;  // zero-based number the event carries (-1 = off)
static CGEventFlags KEYS;   // required modifier mask
static int SPEED;
static int KEYCODE;         // activation key virtual keycode (NO_KEYCODE = off)
static bool KEY_TOGGLE;     // activation key toggles instead of holds
static bool PAUSED;         // user toggled Pause from the menu

static bool BUTTON_ENABLED;
static bool KEY_ENABLED;      // modifier-hold activation (no key configured)
static bool KEYDOWN_ENABLED;  // activation-key activation (hold or toggle)
static bool SWALLOW_UP;       // swallow the pending keyUp for the activation key
static CGPoint POINT;

static CFMachPortRef gTap;
static CFRunLoopSourceRef gSource;

static inline bool anyEnabled(void)
{
    return BUTTON_ENABLED || KEY_ENABLED || KEYDOWN_ENABLED;
}

static void maybeSetPointAndWarpMouse(bool thisEnabled, bool otherEnabled, CGEventRef event)
{
    if (!otherEnabled) {
        POINT = CGEventGetLocation(event);
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        if (thisEnabled) {
            CGEventSourceSetLocalEventsSuppressionInterval(source, 10.0);
            CGWarpMouseCursorPosition(POINT);
        } else {
            CGEventSourceSetLocalEventsSuppressionInterval(source, 0.0);
            CGWarpMouseCursorPosition(POINT);
            CGEventSourceSetLocalEventsSuppressionInterval(source, 0.25);
        }
        CFRelease(source);
    }
}

static CGEventRef tapCallback(CGEventTapProxy proxy,
                              CGEventType type, CGEventRef event, void *userInfo)
{
    // A tap can be silently disabled by the system; re-enable it.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap)
            CGEventTapEnable(gTap, true);
        return event;
    }

    if (PAUSED)
        return event;

    if (type == kCGEventMouseMoved && anyEnabled()) {
        int deltaX = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int deltaY = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGEventRef scrollWheelEvent = CGEventCreateScrollWheelEvent(
            NULL, kCGScrollEventUnitPixel, 2, -SPEED * deltaY, -SPEED * deltaX
        );
        if (KEY_ENABLED)
            CGEventSetFlags(scrollWheelEvent, CGEventGetFlags(event) & ~KEYS);
        CGEventTapPostEvent(proxy, scrollWheelEvent);
        CFRelease(scrollWheelEvent);
        CGWarpMouseCursorPosition(POINT);
        event = NULL;
    } else if (type == kCGEventOtherMouseDown
               && BUTTON != 0
               && CGEventGetFlags(event) == 0
               && CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) == BUTTON_COMPARE) {
        BUTTON_ENABLED = !BUTTON_ENABLED;
        maybeSetPointAndWarpMouse(BUTTON_ENABLED, KEY_ENABLED || KEYDOWN_ENABLED, event);
        event = NULL;
    } else if (type == kCGEventFlagsChanged && KEYCODE == NO_KEYCODE && KEYS != 0) {
        KEY_ENABLED = (CGEventGetFlags(event) & KEYS) == KEYS;
        maybeSetPointAndWarpMouse(KEY_ENABLED, BUTTON_ENABLED || KEYDOWN_ENABLED, event);
    } else if ((type == kCGEventKeyDown || type == kCGEventKeyUp) && KEYCODE != NO_KEYCODE) {
        int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (code == KEYCODE) {
            if (type == kCGEventKeyDown) {
                bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
                bool modifiersHeld = (CGEventGetFlags(event) & KEYS) == KEYS;
                if (repeat) {
                    if (SWALLOW_UP)  // suppress auto-repeat while the key is armed
                        event = NULL;
                } else if (modifiersHeld) {
                    if (KEY_TOGGLE)
                        KEYDOWN_ENABLED = !KEYDOWN_ENABLED;  // press on / press off
                    else
                        KEYDOWN_ENABLED = true;              // hold to scroll
                    maybeSetPointAndWarpMouse(KEYDOWN_ENABLED, BUTTON_ENABLED || KEY_ENABLED, event);
                    SWALLOW_UP = true;
                    event = NULL;
                }
            } else { // keyUp
                if (!KEY_TOGGLE && KEYDOWN_ENABLED) {
                    KEYDOWN_ENABLED = false;
                    maybeSetPointAndWarpMouse(KEYDOWN_ENABLED, BUTTON_ENABLED || KEY_ENABLED, event);
                }
                if (SWALLOW_UP) {
                    SWALLOW_UP = false;
                    event = NULL;
                }
            }
        }
    }

    return event;
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

static bool getIntPreference(CFStringRef key, int *valuePtr)
{
    CFNumberRef number = (CFNumberRef)CFPreferencesCopyAppValue(
        key, kCFPreferencesCurrentApplication
    );
    bool got = false;
    if (number) {
        if (CFGetTypeID(number) == CFNumberGetTypeID())
            got = CFNumberGetValue(number, kCFNumberIntType, valuePtr);
        CFRelease(number);
    }
    return got;
}

static bool getArrayPreference(CFStringRef key, CFStringRef *values, int *count, int maxCount)
{
    CFArrayRef array = (CFArrayRef)CFPreferencesCopyAppValue(
        key, kCFPreferencesCurrentApplication
    );
    bool got = false;
    if (array) {
        if (CFGetTypeID(array) == CFArrayGetTypeID()) {
            CFIndex c = CFArrayGetCount(array);
            if (c <= maxCount) {
                CFArrayGetValues(array, CFRangeMake(0, c), (const void **)values);
                *count = (int)c;
                got = true;
            }
        }
        CFRelease(array);
    }
    return got;
}

static void setIntPreference(NSString *key, int value)
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(value),
                             kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

static void setObjectPreference(NSString *key, id value)
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

static void removePreference(NSString *key)
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                             kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

// ---------------------------------------------------------------------------
// Event tap installation
// ---------------------------------------------------------------------------

static void loadConfiguration(void)
{
    if (!(getIntPreference(CFSTR("button"), &BUTTON)
          && (BUTTON == 0 || (BUTTON >= 3 && BUTTON <= 32))))
        BUTTON = DEFAULT_BUTTON;
    BUTTON_COMPARE = (BUTTON != 0) ? BUTTON - 1 : -1;

    CFStringRef keyNames[MAX_KEY_COUNT];
    int keyCount;
    if (getArrayPreference(CFSTR("keys"), keyNames, &keyCount, MAX_KEY_COUNT)) {
        KEYS = 0;
        for (int i = 0; i < keyCount; i++) {
            if (EQ(keyNames[i], CFSTR("capslock"))) {
                KEYS |= kCGEventFlagMaskAlphaShift;
            } else if (EQ(keyNames[i], CFSTR("shift"))) {
                KEYS |= kCGEventFlagMaskShift;
            } else if (EQ(keyNames[i], CFSTR("control"))) {
                KEYS |= kCGEventFlagMaskControl;
            } else if (EQ(keyNames[i], CFSTR("option"))) {
                KEYS |= kCGEventFlagMaskAlternate;
            } else if (EQ(keyNames[i], CFSTR("command"))) {
                KEYS |= kCGEventFlagMaskCommand;
            } else {
                KEYS = DEFAULT_KEYS;
                break;
            }
        }
    } else {
        KEYS = DEFAULT_KEYS;
    }

    if (!getIntPreference(CFSTR("speed"), &SPEED))
        SPEED = DEFAULT_SPEED;

    if (!getIntPreference(CFSTR("keyCode"), &KEYCODE) || KEYCODE < 0)
        KEYCODE = NO_KEYCODE;

    int toggle;
    KEY_TOGGLE = getIntPreference(CFSTR("keyToggle"), &toggle) && toggle != 0;
}

static void removeTap(void)
{
    if (gSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), gSource, kCFRunLoopDefaultMode);
        CFRelease(gSource);
        gSource = NULL;
    }
    if (gTap) {
        CGEventTapEnable(gTap, false);
        CFRelease(gTap);
        gTap = NULL;
    }
}

static bool installTap(void)
{
    removeTap();

    // Activation state is reset whenever the tap is rebuilt.
    BUTTON_ENABLED = KEY_ENABLED = KEYDOWN_ENABLED = SWALLOW_UP = false;

    CGEventMask events = CGEventMaskBit(kCGEventMouseMoved);
    if (BUTTON != 0)
        events |= CGEventMaskBit(kCGEventOtherMouseDown);
    if (KEYCODE != NO_KEYCODE)
        events |= CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    else if (KEYS != 0)
        events |= CGEventMaskBit(kCGEventFlagsChanged);

    gTap = CGEventTapCreate(
        kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
        events, tapCallback, NULL
    );
    if (!gTap)
        return false;
    gSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gTap, 0);
    if (!gSource) {
        CFRelease(gTap);
        gTap = NULL;
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), gSource, kCFRunLoopDefaultMode);
    return true;
}

// ---------------------------------------------------------------------------
// Key labels
// ---------------------------------------------------------------------------

static NSString *labelForKeyEvent(NSEvent *event)
{
    switch (event.keyCode) {
        case kVK_Space:        return @"Space";
        case kVK_Return:       return @"Return";
        case kVK_Tab:          return @"Tab";
        case kVK_Delete:       return @"Delete";
        case kVK_ForwardDelete:return @"Fwd Delete";
        case kVK_Escape:       return @"Escape";
        case kVK_LeftArrow:    return @"←";
        case kVK_RightArrow:   return @"→";
        case kVK_UpArrow:      return @"↑";
        case kVK_DownArrow:    return @"↓";
        case kVK_Home:         return @"Home";
        case kVK_End:          return @"End";
        case kVK_PageUp:       return @"Page Up";
        case kVK_PageDown:     return @"Page Down";
        case kVK_F1:  return @"F1";  case kVK_F2:  return @"F2";
        case kVK_F3:  return @"F3";  case kVK_F4:  return @"F4";
        case kVK_F5:  return @"F5";  case kVK_F6:  return @"F6";
        case kVK_F7:  return @"F7";  case kVK_F8:  return @"F8";
        case kVK_F9:  return @"F9";  case kVK_F10: return @"F10";
        case kVK_F11: return @"F11"; case kVK_F12: return @"F12";
        default: break;
    }
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c >= ' ' && c != 0x7f)
            return chars.uppercaseString;
    }
    return [NSString stringWithFormat:@"Key %d", event.keyCode];
}

// ---------------------------------------------------------------------------
// Launch at login
// ---------------------------------------------------------------------------

static NSURL *legacyLaunchAgentURL(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.emreyolcu.DragScroll";
    NSString *file = [bundleID stringByAppendingPathExtension:@"plist"];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:file]];
}

static BOOL isLoginItemEnabled(void)
{
    if (@available(macOS 13.0, *))
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    return [[NSFileManager defaultManager] fileExistsAtPath:legacyLaunchAgentURL().path];
}

static void setLoginItemEnabled(BOOL enabled)
{
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        if (enabled)
            [service registerAndReturnError:&error];
        else
            [service unregisterAndReturnError:&error];
        if (error)
            NSLog(@"DragScroll: login item change failed: %@", error);
        return;
    }

    // Fallback for < macOS 13: a per-user LaunchAgent.
    NSURL *url = legacyLaunchAgentURL();
    if (enabled) {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.emreyolcu.DragScroll";
        NSDictionary *plist = @{
            @"Label": bundleID,
            @"ProgramArguments": @[exe ?: @""],
            @"RunAtLoad": @YES,
        };
        [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
        [plist writeToURL:url atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@end

static void axChanged(CFNotificationCenterRef center, void *observer,
                      CFNotificationName name, const void *object,
                      CFDictionaryRef userInfo);

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    NSPopover    *_popover;

    NSTextField  *_statusLabel;
    NSButton     *_pauseButton;
    NSTextField  *_speedField;
    NSStepper    *_speedStepper;
    NSPopUpButton *_buttonPopup;
    NSButton     *_modifierChecks[5];
    NSButton     *_recordButton;
    NSButton     *_clearKeyButton;
    NSButton     *_keyToggleCheck;
    NSButton     *_loginCheck;

    id           _recordMonitor;

    char         _axObserver;
}

// -- lifecycle -------------------------------------------------------------

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    loadConfiguration();
    [self setUpStatusItem];

    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)&kAXTrustedCheckOptionPrompt, (const void **)&kCFBooleanTrue, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    TRUSTED = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);

    if (TRUSTED) {
        installTap();
    } else {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), &_axObserver,
            axChanged, AX_NOTIFICATION, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
    [self updateMenuState];
}

static void axChanged(CFNotificationCenterRef center, void *observer,
                      CFNotificationName name, const void *object,
                      CFDictionaryRef userInfo)
{
    bool previouslyTrusted = TRUSTED;
    if ((TRUSTED = AXIsProcessTrusted()) && !previouslyTrusted) {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer, AX_NOTIFICATION, NULL
        );
        installTap();
        [(AppDelegate *)[NSApp delegate] updateMenuState];
    }
}

// -- status item + popover -------------------------------------------------

- (void)setUpStatusItem
{
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSImage *image = nil;
    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:@"arrow.up.and.down.and.arrow.left.and.right"
                         accessibilityDescription:@"DragScroll"];
    }
    if (image) {
        image.template = YES;
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"⇅";
    }
    _statusItem.button.toolTip = @"DragScroll";
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(togglePopover:);

    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = [self buildContentView];

    _popover = [[NSPopover alloc] init];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.delegate = self;
    _popover.contentViewController = vc;
    _popover.contentSize = vc.view.frame.size;
}

- (void)togglePopover:(id)sender
{
    if (_popover.isShown) {
        [_popover close];
        return;
    }
    [self syncSettingsControls];
    [self updateMenuState];
    NSStatusBarButton *button = _statusItem.button;
    [_popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)popoverDidClose:(NSNotification *)note
{
    [self endRecording];
}

- (void)updateMenuState
{
    if (!TRUSTED)
        _statusLabel.stringValue = @"⚠ Waiting for Accessibility access";
    else if (PAUSED)
        _statusLabel.stringValue = @"Paused";
    else
        _statusLabel.stringValue = @"Active";
    _pauseButton.title = PAUSED ? @"Resume" : @"Pause";
}

- (void)togglePause:(id)sender
{
    PAUSED = !PAUSED;
    BUTTON_ENABLED = KEY_ENABLED = KEYDOWN_ENABLED = SWALLOW_UP = false;
    [self updateMenuState];
}

- (void)quit:(id)sender
{
    [NSApp terminate:nil];
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame bold:(BOOL)bold
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = string;
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:12];
    if (!bold)
        label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSView *)buildContentView
{
    NSRect frame = NSMakeRect(0, 0, 460, 500);
    NSView *root = [[NSView alloc] initWithFrame:frame];

    CGFloat W = frame.size.width;
    CGFloat labelX = 20;
    CGFloat ctrlX = 150;
    CGFloat ctrlW = W - ctrlX - 20;

    // -- Header (app name + live status) --
    NSTextField *title = [self labelWithString:@"DragScroll"
                                         frame:NSMakeRect(labelX, frame.size.height - 34, 160, 20)
                                          bold:YES];
    [root addSubview:title];
    _statusLabel = [self labelWithString:@""
                                   frame:NSMakeRect(W - 220, frame.size.height - 33, 200, 18)
                                    bold:NO];
    _statusLabel.alignment = NSTextAlignmentRight;
    [root addSubview:_statusLabel];

    NSBox *topSep = [[NSBox alloc] initWithFrame:NSMakeRect(16, frame.size.height - 46, W - 32, 1)];
    topSep.boxType = NSBoxSeparator;
    [root addSubview:topSep];

    CGFloat y = frame.size.height - 78;  // top of controls, working downward

    // -- Scrolling speed --
    [root addSubview:[self labelWithString:@"Scrolling speed:"
                                     frame:NSMakeRect(labelX, y, 120, 20) bold:NO]];
    _speedStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(ctrlX + 60, y - 2, 20, 24)];
    _speedStepper.minValue = -30;
    _speedStepper.maxValue = 30;
    _speedStepper.increment = 1;
    _speedStepper.valueWraps = NO;
    _speedStepper.target = self;
    _speedStepper.action = @selector(speedStepperChanged:);
    [root addSubview:_speedStepper];
    _speedField = [[NSTextField alloc] initWithFrame:NSMakeRect(ctrlX, y - 2, 54, 22)];
    _speedField.alignment = NSTextAlignmentCenter;
    _speedField.target = self;
    _speedField.action = @selector(speedFieldChanged:);
    [root addSubview:_speedField];
    [root addSubview:[self labelWithString:@"negative inverts scroll direction"
                                     frame:NSMakeRect(labelX, y - 22, W - 40, 16) bold:NO]];
    y -= 58;

    // -- Mouse button --
    [root addSubview:[self labelWithString:@"Mouse button:"
                                     frame:NSMakeRect(labelX, y, 120, 20) bold:NO]];
    _buttonPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(ctrlX, y - 3, ctrlW, 26)];
    [_buttonPopup addItemWithTitle:@"Off"];
    [_buttonPopup.lastItem setTag:0];
    for (int b = 3; b <= 32; b++) {
        [_buttonPopup addItemWithTitle:[NSString stringWithFormat:@"Button %d", b]];
        [_buttonPopup.lastItem setTag:b];
    }
    _buttonPopup.target = self;
    _buttonPopup.action = @selector(buttonChanged:);
    [root addSubview:_buttonPopup];
    y -= 44;

    // -- Modifier keys --
    [root addSubview:[self labelWithString:@"Modifier keys:"
                                     frame:NSMakeRect(labelX, y, 120, 20) bold:NO]];
    CGFloat cx = ctrlX;
    CGFloat cy = y;
    for (int i = 0; i < MODIFIER_COUNT; i++) {
        NSButton *check = [[NSButton alloc] initWithFrame:NSMakeRect(cx, cy, 150, 20)];
        [check setButtonType:NSButtonTypeSwitch];
        check.title = MODIFIER_TITLES[i];
        check.tag = i;
        check.target = self;
        check.action = @selector(modifiersChanged:);
        [root addSubview:check];
        _modifierChecks[i] = check;
        cy -= 24;
    }
    y = cy - 10;

    // -- Activation key --
    [root addSubview:[self labelWithString:@"Activation key:"
                                     frame:NSMakeRect(labelX, y, 120, 20) bold:NO]];
    _recordButton = [[NSButton alloc] initWithFrame:NSMakeRect(ctrlX, y - 4, 160, 26)];
    _recordButton.bezelStyle = NSBezelStyleRounded;
    _recordButton.target = self;
    _recordButton.action = @selector(recordKey:);
    [root addSubview:_recordButton];
    _clearKeyButton = [[NSButton alloc] initWithFrame:NSMakeRect(ctrlX + 168, y - 4, 70, 26)];
    _clearKeyButton.bezelStyle = NSBezelStyleRounded;
    _clearKeyButton.title = @"Clear";
    _clearKeyButton.target = self;
    _clearKeyButton.action = @selector(clearKey:);
    [root addSubview:_clearKeyButton];
    [root addSubview:[self labelWithString:@"held with the modifiers above; won’t type while active"
                                     frame:NSMakeRect(labelX, y - 24, W - 40, 16) bold:NO]];
    y -= 50;

    // -- Activation key behavior --
    [root addSubview:[self labelWithString:@"Key behavior:"
                                     frame:NSMakeRect(labelX, y, 120, 20) bold:NO]];
    _keyToggleCheck = [[NSButton alloc] initWithFrame:NSMakeRect(ctrlX, y, ctrlW, 20)];
    [_keyToggleCheck setButtonType:NSButtonTypeSwitch];
    _keyToggleCheck.title = @"Toggle (press to start, press again to stop)";
    _keyToggleCheck.target = self;
    _keyToggleCheck.action = @selector(keyToggleChanged:);
    [root addSubview:_keyToggleCheck];
    y -= 34;

    // -- Launch at login --
    _loginCheck = [[NSButton alloc] initWithFrame:NSMakeRect(labelX, y, W - 40, 20)];
    [_loginCheck setButtonType:NSButtonTypeSwitch];
    _loginCheck.title = @"Launch DragScroll at login";
    _loginCheck.target = self;
    _loginCheck.action = @selector(loginChanged:);
    [root addSubview:_loginCheck];

    // -- Footer (Pause / Quit) --
    NSBox *bottomSep = [[NSBox alloc] initWithFrame:NSMakeRect(16, 56, W - 32, 1)];
    bottomSep.boxType = NSBoxSeparator;
    [root addSubview:bottomSep];

    _pauseButton = [[NSButton alloc] initWithFrame:NSMakeRect(labelX, 16, 120, 28)];
    _pauseButton.bezelStyle = NSBezelStyleRounded;
    _pauseButton.title = @"Pause";
    _pauseButton.target = self;
    _pauseButton.action = @selector(togglePause:);
    [root addSubview:_pauseButton];

    NSButton *quitButton = [[NSButton alloc] initWithFrame:NSMakeRect(W - labelX - 120, 16, 120, 28)];
    quitButton.bezelStyle = NSBezelStyleRounded;
    quitButton.title = @"Quit DragScroll";
    quitButton.target = self;
    quitButton.action = @selector(quit:);
    [root addSubview:quitButton];

    return root;
}

- (void)syncSettingsControls
{
    _speedStepper.integerValue = SPEED;
    _speedField.integerValue = SPEED;

    [_buttonPopup selectItemWithTag:BUTTON];

    for (int i = 0; i < MODIFIER_COUNT; i++)
        _modifierChecks[i].state = (KEYS & MODIFIER_MASKS[i]) ? NSControlStateValueOn
                                                              : NSControlStateValueOff;

    NSString *keyLabel = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefKeyLabel];
    if (KEYCODE != NO_KEYCODE && keyLabel.length)
        _recordButton.title = keyLabel;
    else
        _recordButton.title = @"Click to set…";
    _clearKeyButton.enabled = (KEYCODE != NO_KEYCODE);

    _keyToggleCheck.state = KEY_TOGGLE ? NSControlStateValueOn : NSControlStateValueOff;
    _keyToggleCheck.enabled = (KEYCODE != NO_KEYCODE);

    _loginCheck.state = isLoginItemEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

// -- settings actions ------------------------------------------------------

- (void)applyChanges
{
    loadConfiguration();
    if (TRUSTED)
        installTap();
    [self updateMenuState];
}

- (void)speedStepperChanged:(id)sender
{
    setIntPreference(kPrefSpeed, (int)_speedStepper.integerValue);
    _speedField.integerValue = _speedStepper.integerValue;
    [self applyChanges];
}

- (void)speedFieldChanged:(id)sender
{
    int value = (int)_speedField.integerValue;
    if (value < -30) value = -30;
    if (value > 30)  value = 30;
    _speedField.integerValue = value;
    _speedStepper.integerValue = value;
    setIntPreference(kPrefSpeed, value);
    [self applyChanges];
}

- (void)buttonChanged:(id)sender
{
    setIntPreference(kPrefButton, (int)_buttonPopup.selectedItem.tag);
    [self applyChanges];
}

- (void)keyToggleChanged:(id)sender
{
    setIntPreference(kPrefKeyToggle, _keyToggleCheck.state == NSControlStateValueOn ? 1 : 0);
    [self applyChanges];
}

- (void)modifiersChanged:(id)sender
{
    NSMutableArray *names = [NSMutableArray array];
    for (int i = 0; i < MODIFIER_COUNT; i++)
        if (_modifierChecks[i].state == NSControlStateValueOn)
            [names addObject:MODIFIER_PREF_NAMES[i]];
    setObjectPreference(kPrefKeys, names);
    [self applyChanges];
}

- (void)recordKey:(id)sender
{
    if (_recordMonitor) {
        [self endRecording];
        return;
    }
    _recordButton.title = @"Press a key…  (Esc to cancel)";
    __weak AppDelegate *weakSelf = self;
    _recordMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                           handler:^NSEvent *(NSEvent *event) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf)
            return event;
        if (event.keyCode != kVK_Escape) {
            setIntPreference(kPrefKeyCode, event.keyCode);
            setObjectPreference(kPrefKeyLabel, labelForKeyEvent(event));
            [strongSelf applyChanges];
        }
        [strongSelf endRecording];
        return nil;  // swallow so the key doesn't act on the window
    }];
}

- (void)endRecording
{
    if (_recordMonitor) {
        [NSEvent removeMonitor:_recordMonitor];
        _recordMonitor = nil;
    }
    [self syncSettingsControls];
}

- (void)clearKey:(id)sender
{
    removePreference(kPrefKeyCode);
    removePreference(kPrefKeyLabel);
    [self applyChanges];
    [self syncSettingsControls];
}

- (void)loginChanged:(id)sender
{
    setLoginItemEnabled(_loginCheck.state == NSControlStateValueOn);
    _loginCheck.state = isLoginItemEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

@end

int main(void)
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return EXIT_SUCCESS;
}

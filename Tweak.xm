// Tweak.xm
// Injects BlueShare "Share to Android" into every share sheet across iOS.
// Starts the unsandboxed HTTP transfer daemon in SpringBoard.
// Author: Sanket Yadav

#import <UIKit/UIKit.h>
#import "BTShareActivity.h"
#import "DevicePickerViewController.h"

// ── Preferences helper ────────────────────────────────────────────────────────
static BOOL bsEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.yourrepo.blueshare.plist"];
    if (!prefs) return YES;
    NSNumber *val = prefs[@"BSEnabled"];
    return val ? val.boolValue : YES;
}

// ── Helper to ensure BTShareActivity is in an activities array ────────────────
static NSArray *injectBTShareActivity(NSArray *activities) {
    if (!bsEnabled()) return activities;
    for (id act in activities) {
        if ([act isKindOfClass:[BTShareActivity class]]) {
            return activities;
        }
    }
    NSMutableArray *mut = activities ? [activities mutableCopy] : [NSMutableArray new];
    [mut addObject:[BTShareActivity new]];
    return [mut copy];
}

// ── Hook UIActivityViewController ─────────────────────────────────────────────
%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray *)applicationActivities {
    applicationActivities = injectBTShareActivity(applicationActivities);
    return %orig(activityItems, applicationActivities);
}

- (id)_initWithActivityItems:(id)items applicationActivities:(id)activities excludedActivityTypes:(id)excluded {
    activities = injectBTShareActivity(activities);
    return %orig(items, activities, excluded);
}

- (id)_initWithActivityItems:(id)items applicationActivities:(id)activities {
    activities = injectBTShareActivity(activities);
    return %orig(items, activities);
}

%end

// ── Constructor ───────────────────────────────────────────────────────────────
%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;

    // When running inside SpringBoard (unsandboxed): start the transfer daemon!
    if ([bundleID isEqualToString:@"com.apple.springboard"]) {
        NSLog(@"[BlueShare] Injected into SpringBoard (unsandboxed). Starting transfer server...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[BSSimpleHTTPServer sharedServer] startListening];
        });
        return;
    }

    // Safety guard: NEVER inject or touch package managers / system daemons
    if ([bundleID hasPrefix:@"org.coolstar"] ||
        [bundleID isEqualToString:@"xyz.willy.Zebra"] ||
        [bundleID isEqualToString:@"com.tigisoftware.Filza"] ||
        [bundleID isEqualToString:@"org.cydia.Cydia"] ||
        [bundleID isEqualToString:@"com.saurik.Cydia"]) {
        return;
    }
}

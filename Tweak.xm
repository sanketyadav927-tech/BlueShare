// Tweak.xm
// Injects BlueShare "Send via Bluetooth" into every share sheet across iOS.
// Author: Sanket Yadav

#import <UIKit/UIKit.h>
#import "BTShareActivity.h"

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

- (NSArray *)applicationActivities {
    return injectBTShareActivity(%orig);
}

- (NSArray *)_customActivities {
    return injectBTShareActivity(%orig);
}

- (void)viewDidLoad {
    %orig;
    @try {
        if (bsEnabled()) {
            NSArray *current = [self applicationActivities];
            BOOL found = NO;
            for (id act in current) {
                if ([act isKindOfClass:[BTShareActivity class]]) {
                    found = YES;
                    break;
                }
            }
            if (!found) {
                NSMutableArray *mut = current ? [current mutableCopy] : [NSMutableArray new];
                [mut addObject:[BTShareActivity new]];
                @try {
                    [self setValue:[mut copy] forKey:@"_applicationActivities"];
                } @catch (NSException *_) {}
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[BlueShare] viewDidLoad hook error: %@", e);
    }
}

%end

// ── Constructor ───────────────────────────────────────────────────────────────
%ctor {
    // Safety guard: NEVER inject or touch package managers / system daemons
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if ([bundleID hasPrefix:@"org.coolstar"] ||
        [bundleID isEqualToString:@"xyz.willy.Zebra"] ||
        [bundleID isEqualToString:@"com.tigisoftware.Filza"] ||
        [bundleID isEqualToString:@"org.cydia.Cydia"] ||
        [bundleID isEqualToString:@"com.saurik.Cydia"]) {
        return; // Early return: do not hook package managers!
    }

    // Do NOT start Bluetooth advertising here!
    // The background daemon (BTShareDaemon) handles incoming connections.
}

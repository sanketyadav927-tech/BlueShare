// Tweak.xm
// Hooks UIActivityViewController to inject the BlueShare "Send via Bluetooth"
// activity into every share sheet on the system.

#import <UIKit/UIKit.h>
#import "BTShareActivity.h"
#import "TransferManager.h"

// ── Preferences helper ────────────────────────────────────────────────────────
static BOOL bsEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.yourrepo.blueshare.plist"];
    if (!prefs) return YES; // default on
    NSNumber *val = prefs[@"BSEnabled"];
    return val ? val.boolValue : YES;
}

// ── Hook UIActivityViewController ─────────────────────────────────────────────
%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray *)applicationActivities {
    // Only inject when tweak is enabled
    if (bsEnabled()) {
        NSMutableArray *activities = applicationActivities
            ? [applicationActivities mutableCopy]
            : [NSMutableArray new];

        // Check that at least one item is a file/image before showing the activity
        BOOL hasShareable = NO;
        for (id item in activityItems) {
            if ([item isKindOfClass:[NSURL class]] && [(NSURL *)item isFileURL]) { hasShareable = YES; break; }
            if ([item isKindOfClass:[UIImage class]])                            { hasShareable = YES; break; }
            if ([item isKindOfClass:[NSData class]])                             { hasShareable = YES; break; }
        }

        if (hasShareable) {
            [activities insertObject:[BTShareActivity new] atIndex:0];
        }
        applicationActivities = [activities copy];
    }
    return %orig(activityItems, applicationActivities);
}

%end

// ── Constructor ───────────────────────────────────────────────────────────────
%ctor {
    // Start the peripheral (receiver) immediately so the device can be found
    // by other BlueShare senders even without opening any app.
    // The daemon handles this when SpringBoard isn't the active process,
    // but having it here ensures in-app receipt works too.
    [[BSTransferManager sharedManager] startAdvertising];

    // Set up delegate to handle incoming file requests inside SpringBoard
    // (The daemon duplicates this for background receipt.)
    [BSTransferManager sharedManager].delegate = (id)[[NSObject alloc] init];
}

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
    if (bsEnabled()) {
        NSMutableArray *activities = applicationActivities
            ? [applicationActivities mutableCopy]
            : [NSMutableArray new];

        // Always insert BlueShare activity into every share sheet
        [activities insertObject:[BTShareActivity new] atIndex:0];
        applicationActivities = [activities copy];
    }
    return %orig(activityItems, applicationActivities);
}

%end

// ── Constructor ───────────────────────────────────────────────────────────────
%ctor {
    // Start advertising so this device is discoverable by other BlueShare senders.
    // The daemon handles incoming transfers in the background.
    [[BSTransferManager sharedManager] startAdvertising];
}

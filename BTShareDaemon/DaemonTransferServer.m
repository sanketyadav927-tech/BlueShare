// BTShareDaemon/DaemonTransferServer.m
// Runs in the BTShareDaemon process. Bridges TransferManager callbacks to
// local UNUserNotifications so the user can Accept/Decline incoming transfers.

#import "DaemonTransferServer.h"
#import "TransferManager.h"
#import <UserNotifications/UserNotifications.h>

// Notification category & action identifiers
static NSString *const kBSCategory       = @"BS_INCOMING";
static NSString *const kBSActionAccept   = @"BS_ACCEPT";
static NSString *const kBSActionDecline  = @"BS_DECLINE";

@interface DaemonTransferServer () <BSTransferManagerDelegate,
                                    UNUserNotificationCenterDelegate>
@property (nonatomic, copy) void (^pendingAccept)(BOOL);
@end

@implementation DaemonTransferServer

+ (instancetype)sharedServer {
    static DaemonTransferServer *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}

- (void)start {
    [self registerNotificationCategories];
    [BSTransferManager sharedManager].delegate = self;
    [[BSTransferManager sharedManager] startAdvertising];
    NSLog(@"[BTShareDaemon] Started advertising.");
}

- (void)stop {
    [[BSTransferManager sharedManager] stopAdvertising];
}

// ── Notification setup ────────────────────────────────────────────────────────

- (void)registerNotificationCategories {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;

    UNNotificationAction *acceptAction = [UNNotificationAction
        actionWithIdentifier:kBSActionAccept
                       title:@"Accept"
                     options:UNNotificationActionOptionForeground];

    UNNotificationAction *declineAction = [UNNotificationAction
        actionWithIdentifier:kBSActionDecline
                       title:@"Decline"
                     options:UNNotificationActionOptionDestructive];

    UNNotificationCategory *category = [UNNotificationCategory
        categoryWithIdentifier:kBSCategory
                       actions:@[acceptAction, declineAction]
             intentIdentifiers:@[]
                       options:UNNotificationCategoryOptionNone];

    [center setNotificationCategories:[NSSet setWithObject:category]];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *_) {
        NSLog(@"[BTShareDaemon] Notification permission granted: %d", granted);
    }];
}

// ── BSTransferManagerDelegate ─────────────────────────────────────────────────

- (void)transferManager:(id)mgr
    didReceiveIncomingRequestFrom:(NSString *)senderName
                         metadata:(BSTransferMetadata *)meta
                      acceptBlock:(void (^)(BOOL))acceptBlock {

    self.pendingAccept = acceptBlock;

    // Fire a local notification with Accept/Decline actions
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title    = @"Incoming Bluetooth File";
    content.body     = [NSString stringWithFormat:@"%@ wants to send you "%@" (%.1f KB)",
                        senderName, meta.fileName, meta.totalBytes / 1024.0];
    content.sound    = [UNNotificationSound defaultSound];
    content.categoryIdentifier = kBSCategory;

    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:@"BS_INCOMING"
                      content:content
                      trigger:nil]; // deliver immediately

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:nil];
}

- (void)transferManager:(id)mgr receiveProgress:(float)progress {
    NSLog(@"[BTShareDaemon] Receive progress: %.0f%%", progress * 100);
}

- (void)transferManager:(id)mgr didReceiveFileAtPath:(NSString *)path {
    // Notify user that the file arrived
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"File Received ✅";
    content.body  = [NSString stringWithFormat:@""%@" saved to BlueShare folder.",
                     path.lastPathComponent];
    content.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:@"BS_DONE"
                      content:content
                      trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:nil];

    NSLog(@"[BTShareDaemon] File saved: %@", path);
}

// ── UNUserNotificationCenterDelegate ─────────────────────────────────────────

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {

    BOOL accepted = [response.actionIdentifier isEqualToString:kBSActionAccept];
    if (self.pendingAccept) {
        self.pendingAccept(accepted);
        self.pendingAccept = nil;
    }
    completionHandler();
}

@end

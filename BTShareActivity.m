// BTShareActivity.m
// UIActivity subclass that drives the "Send via Bluetooth" share sheet entry.
// When performed, it presents DevicePickerViewController modally.

#import "BTShareActivity.h"
#import "DevicePickerViewController.h"

@interface BTShareActivity ()
@property (nonatomic, strong) NSArray *activityItems;
@end

@implementation BTShareActivity

// ── UIActivity identity ───────────────────────────────────────────────────────

+ (UIActivityCategory)activityCategory {
    return UIActivityCategoryShare;
}

- (NSString *)activityType {
    return @"com.yourrepo.blueshare.send";
}

- (NSString *)activityTitle {
    return @"Send via Bluetooth";
}

- (UIImage *)activityImage {
    // SF Symbol available iOS 13+
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:28 weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
                   withConfiguration:cfg];
}

// ── Supported item types ──────────────────────────────────────────────────────

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    for (id item in activityItems) {
        // Accept file URLs and raw data objects
        if ([item isKindOfClass:[NSURL class]] && [(NSURL *)item isFileURL]) return YES;
        if ([item isKindOfClass:[NSData class]])                              return YES;
        if ([item isKindOfClass:[UIImage class]])                             return YES;
    }
    return NO;
}

- (void)prepareWithActivityItems:(NSArray *)activityItems {
    self.activityItems = activityItems;
}

// ── Perform ───────────────────────────────────────────────────────────────────

- (void)performActivity {
    // Resolve items to file URLs (write images/data to temp files if needed)
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray new];
    for (id item in self.activityItems) {
        NSURL *url = [self resolveItemToFileURL:item];
        if (url) [fileURLs addObject:url];
    }

    if (fileURLs.count == 0) {
        [self activityDidFinish:NO];
        return;
    }

    // Present device picker
    DevicePickerViewController *picker = [[DevicePickerViewController alloc]
        initWithFileURLs:fileURLs];
    picker.completionHandler = ^(BOOL success) {
        [self activityDidFinish:success];
    };

    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;

    // Find the root view controller from the active window scene
    UIViewController *rootVC = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    rootVC = window.rootViewController;
                    break;
                }
            }
        }
        if (rootVC) break;
    }
    [rootVC presentViewController:nav animated:YES completion:nil];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (nullable NSURL *)resolveItemToFileURL:(id)item {
    if ([item isKindOfClass:[NSURL class]] && [(NSURL *)item isFileURL]) {
        return (NSURL *)item;
    }
    // Write UIImage to a temp PNG
    if ([item isKindOfClass:[UIImage class]]) {
        NSData *png = UIImagePNGRepresentation((UIImage *)item);
        NSURL *tmp  = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                        URLByAppendingPathComponent:@"BlueShare_image.png"];
        [png writeToURL:tmp atomically:YES];
        return tmp;
    }
    // Write raw NSData to a temp file
    if ([item isKindOfClass:[NSData class]]) {
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                       URLByAppendingPathComponent:@"BlueShare_file.bin"];
        [(NSData *)item writeToURL:tmp atomically:YES];
        return tmp;
    }
    return nil;
}

@end

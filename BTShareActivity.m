// BTShareActivity.m
// UIActivity subclass that drives the "Send via Bluetooth" share sheet entry.
// When performed, it presents DevicePickerViewController modally.

#import "BTShareActivity.h"
#import "DevicePickerViewController.h"

@interface BTShareActivity ()
@property (nonatomic, strong) NSArray *activityItems;
@property (nonatomic, strong) UINavigationController *navController;
@end

@implementation BTShareActivity

// ── UIActivity identity ───────────────────────────────────────────────────────

+ (UIActivityCategory)activityCategory {
    return UIActivityCategoryAction;
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
        configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
                   withConfiguration:cfg];
}

// ── Supported item types ──────────────────────────────────────────────────────

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    return YES;
}

- (void)prepareWithActivityItems:(NSArray *)activityItems {
    self.activityItems = activityItems;

    // Resolve items to file URLs (photos, files, raw data, etc.)
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray new];
    for (id item in self.activityItems) {
        NSURL *url = [self resolveItemToFileURL:item];
        if (url) [fileURLs addObject:url];
    }

    if (fileURLs.count == 0) {
        // Fallback placeholder so picker always opens
        NSString *name = [NSString stringWithFormat:@"share_%ld.txt", (long)[[NSDate date] timeIntervalSince1970]];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
        [@"Shared content" writeToURL:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fileURLs addObject:tmp];
    }

    // Present device picker
    DevicePickerViewController *picker = [[DevicePickerViewController alloc]
        initWithFileURLs:fileURLs];
    __weak typeof(self) weakSelf = self;
    picker.completionHandler = ^(BOOL success) {
        [weakSelf activityDidFinish:success];
    };

    self.navController = [[UINavigationController alloc]
        initWithRootViewController:picker];
    self.navController.modalPresentationStyle = UIModalPresentationFormSheet;
}

- (UIViewController *)activityViewController {
    return self.navController;
}

// ── Perform ───────────────────────────────────────────────────────────────────

- (void)performActivity {
    // If iOS didn't auto-present activityViewController, present it on topmost VC
    if (self.navController) {
        UIViewController *topVC = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        topVC = window.rootViewController;
                        break;
                    }
                }
            }
            if (topVC) break;
        }
        if (!topVC) {
            topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        }
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        if (topVC && topVC != self.navController) {
            [topVC presentViewController:self.navController animated:YES completion:nil];
            return;
        }
    }
    [self activityDidFinish:YES];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (nullable NSURL *)resolveItemToFileURL:(id)rawItem {
    id item = rawItem;

    // If it's a provider that responds to item selector
    if ([item respondsToSelector:@selector(item)]) {
        @try {
            id inner = [item performSelector:@selector(item)];
            if (inner) item = inner;
        } @catch (NSException *_) {}
    }

    // Direct file URL
    if ([item isKindOfClass:[NSURL class]]) {
        NSURL *url = (NSURL *)item;
        if (url.isFileURL) return url;
    }

    // UIImage (Photos app)
    if ([item isKindOfClass:[UIImage class]]) {
        UIImage *img = (UIImage *)item;
        NSData *data = UIImageJPEGRepresentation(img, 0.95) ?: UIImagePNGRepresentation(img);
        if (data) {
            NSString *name = [NSString stringWithFormat:@"photo_%ld.jpg",
                              (long)[[NSDate date] timeIntervalSince1970]];
            NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                          URLByAppendingPathComponent:name];
            [data writeToURL:tmp atomically:YES];
            return tmp;
        }
    }

    // Raw NSData
    if ([item isKindOfClass:[NSData class]]) {
        NSString *name = [NSString stringWithFormat:@"file_%ld.bin",
                          (long)[[NSDate date] timeIntervalSince1970]];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                      URLByAppendingPathComponent:name];
        [(NSData *)item writeToURL:tmp atomically:YES];
        return tmp;
    }

    // String / Text
    if ([item isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)item dataUsingEncoding:NSUTF8StringEncoding];
        NSString *name = [NSString stringWithFormat:@"note_%ld.txt",
                          (long)[[NSDate date] timeIntervalSince1970]];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                      URLByAppendingPathComponent:name];
        [data writeToURL:tmp atomically:YES];
        return tmp;
    }

    // NSItemProvider (Photos / Files app async provider)
    if ([item isKindOfClass:[NSItemProvider class]]) {
        NSItemProvider *provider = (NSItemProvider *)item;
        __block NSURL *resolved = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        // Try file representation for image/movie/data types
        NSArray *types = @[@"public.image", @"public.jpeg", @"public.png", @"public.movie", @"public.data", @"public.content"];
        for (NSString *type in types) {
            if ([provider hasItemConformingToTypeIdentifier:type]) {
                [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
                    if (url && url.isFileURL) {
                        NSString *filename = url.lastPathComponent ?: [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
                        NSURL *dest = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:filename];
                        [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
                        [[NSFileManager defaultManager] copyItemAtURL:url toURL:dest error:nil];
                        resolved = dest;
                    }
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
                if (resolved) return resolved;
                break;
            }
        }

        // Try UIImage
        if (!resolved && [provider canLoadObjectOfClass:[UIImage class]]) {
            [provider loadObjectOfClass:[UIImage class]
                      completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if ([obj isKindOfClass:[UIImage class]]) {
                    NSData *data = UIImageJPEGRepresentation((UIImage *)obj, 0.95) ?: UIImagePNGRepresentation((UIImage *)obj);
                    if (data) {
                        NSString *name = [NSString stringWithFormat:@"photo_%ld.jpg",
                                          (long)[[NSDate date] timeIntervalSince1970]];
                        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                                      URLByAppendingPathComponent:name];
                        [data writeToURL:tmp atomically:YES];
                        resolved = tmp;
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
            if (resolved) return resolved;
        }

        // Try NSURL
        if (!resolved && [provider canLoadObjectOfClass:[NSURL class]]) {
            [provider loadObjectOfClass:[NSURL class]
                      completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if ([obj isKindOfClass:[NSURL class]] && [(NSURL *)obj isFileURL]) {
                    resolved = (NSURL *)obj;
                }
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
            if (resolved) return resolved;
        }
    }

    return nil;
}

@end

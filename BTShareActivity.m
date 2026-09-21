// BTShareActivity.m
// UIActivity subclass: "⚡ Share to Android".
// Directly opens the Instant Share transfer interface and resolves any file type from any iOS app.
// Author: Sanket Yadav

#import "BTShareActivity.h"
#import "DevicePickerViewController.h"
#import <objc/message.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>

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
    return @"⚡ Share to Android";
}

- (UIImage *)activityImage {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:@"bolt.horizontal.fill"
                   withConfiguration:cfg]
        ?: [UIImage systemImageNamed:@"qrcode" withConfiguration:cfg];
}

// ── Supported item types ──────────────────────────────────────────────────────

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    return YES;
}

- (void)prepareWithActivityItems:(NSArray *)activityItems {
    self.activityItems = activityItems;

    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray new];
    for (id item in self.activityItems) {
        NSURL *url = [self resolveItemToFileURL:item];
        if (url) {
            [fileURLs addObject:url];
            // Write a shared copy to /var/mobile/Documents/BlueShare/
            @try {
                NSString *dir = @"/var/mobile/Documents/BlueShare";
                [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *sharedPath = [dir stringByAppendingPathComponent:@"shared_photo.jpg"];
                [[NSFileManager defaultManager] removeItemAtPath:sharedPath error:nil];
                [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:sharedPath] error:nil];
            } @catch (NSException *_) {}
        }
    }

    if (fileURLs.count == 0) {
        NSString *name = [NSString stringWithFormat:@"share_%ld.txt", (long)[[NSDate date] timeIntervalSince1970]];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
        [@"Shared content" writeToURL:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fileURLs addObject:tmp];
    }

    // Directly present Instant Share view controller (no bluetooth device picker)
    DevicePickerViewController *shareVC = [[DevicePickerViewController alloc]
        initWithFileURLs:fileURLs];
    __weak typeof(self) weakSelf = self;
    shareVC.completionHandler = ^(BOOL success) {
        [weakSelf activityDidFinish:success];
    };

    self.navController = [[UINavigationController alloc]
        initWithRootViewController:shareVC];
    self.navController.modalPresentationStyle = UIModalPresentationFormSheet;
}

- (UIViewController *)activityViewController {
    return self.navController;
}

// ── Perform ───────────────────────────────────────────────────────────────────

- (void)performActivity {
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

// ── Universal Item Resolver ───────────────────────────────────────────────────

- (nullable NSURL *)resolveItemToFileURL:(id)rawItem {
    id item = rawItem;
    if (!item) return nil;

    // 1. Photos app wrapper unwrapping (PUActivityItemSource, PXActivityItemSourceRecord, etc.)
    if ([item respondsToSelector:@selector(asset)]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id asset = [item performSelector:@selector(asset)];
            #pragma clang diagnostic pop
            if (asset) item = asset;
        } @catch (NSException *_) {}
    }

    // 2. UIActivityItemSource protocol unwrapping
    if ([item respondsToSelector:@selector(activityViewController:itemForActivityType:)]) {
        @try {
            id inner = ((id (*)(id, SEL, id, id))objc_msgSend)(item, @selector(activityViewController:itemForActivityType:), nil, self.activityType);
            if (inner && inner != item) {
                NSURL *u = [self resolveItemToFileURL:inner];
                if (u) return u;
            }
        } @catch (NSException *_) {}
    }

    // 3. UIActivityItemProvider placeholder/item unwrapping
    if ([item respondsToSelector:@selector(item)]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id inner = [item performSelector:@selector(item)];
            #pragma clang diagnostic pop
            if (inner && inner != item) {
                NSURL *u = [self resolveItemToFileURL:inner];
                if (u) return u;
            }
        } @catch (NSException *_) {}
    }

    // 4. Direct file URL (Files app, WhatsApp, Safari downloads, Mail, etc.)
    if ([item isKindOfClass:[NSURL class]]) {
        NSURL *url = (NSURL *)item;
        if (url.isFileURL) return url;
    }

    // 5. UIImage (Photos app, Camera, Screenshot, Safari image)
    if ([item isKindOfClass:[UIImage class]]) {
        UIImage *img = (UIImage *)item;
        NSData *data = UIImageJPEGRepresentation(img, 0.95) ?: UIImagePNGRepresentation(img);
        if (data) {
            NSString *name = [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
            NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
            [data writeToURL:tmp atomically:YES];
            return tmp;
        }
    }

    // 6. PHAsset (Native Photos app items)
    Class PHAssetClass = NSClassFromString(@"PHAsset");
    if (PHAssetClass && [item isKindOfClass:PHAssetClass]) {
        PHAsset *asset = (PHAsset *)item;
        PHImageManager *mgr = [PHImageManager defaultManager];

        if (asset.mediaType == PHAssetMediaTypeImage) {
            PHImageRequestOptions *opts = [PHImageRequestOptions new];
            opts.synchronous = YES;
            opts.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
            opts.networkAccessAllowed = YES;

            __block NSURL *resultURL = nil;

            // Try extracting raw image data
            [mgr requestImageDataAndOrientationForAsset:asset
                                               options:opts
                                         resultHandler:^(NSData *imageData, NSString *dataUTI, CGImagePropertyOrientation orientation, NSDictionary *info) {
                if (imageData && imageData.length > 0) {
                    NSData *finalData = imageData;
                    NSString *ext = @"jpg";
                    // Transcode HEIC to JPEG for Android Gallery compatibility
                    if ([dataUTI.lowercaseString containsString:@"heic"] || [dataUTI.lowercaseString containsString:@"heif"]) {
                        UIImage *img = [UIImage imageWithData:imageData];
                        if (img) {
                            NSData *jpg = UIImageJPEGRepresentation(img, 0.95);
                            if (jpg) finalData = jpg;
                        }
                    } else if ([dataUTI.lowercaseString containsString:@"png"]) {
                        ext = @"png";
                    } else if ([dataUTI.lowercaseString containsString:@"gif"]) {
                        ext = @"gif";
                    }

                    NSString *name = [NSString stringWithFormat:@"photo_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext];
                    NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
                    [finalData writeToURL:tmp atomically:YES];
                    resultURL = tmp;
                }
            }];

            // Fallback to UIImage rendering if raw data extraction was nil
            if (!resultURL) {
                [mgr requestImageForAsset:asset
                               targetSize:CGSizeMake(4000, 4000)
                              contentMode:PHImageContentModeAspectFit
                                  options:opts
                            resultHandler:^(UIImage *result, NSDictionary *info) {
                    if (result) {
                        NSData *jpg = UIImageJPEGRepresentation(result, 0.95);
                        if (jpg) {
                            NSString *name = [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
                            NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
                            [jpg writeToURL:tmp atomically:YES];
                            resultURL = tmp;
                        }
                    }
                }];
            }

            if (resultURL) return resultURL;
        } else if (asset.mediaType == PHAssetMediaTypeVideo) {
            PHVideoRequestOptions *vOpts = [PHVideoRequestOptions new];
            vOpts.networkAccessAllowed = YES;
            vOpts.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;

            dispatch_semaphore_t vSem = dispatch_semaphore_create(0);
            NSString *name = [NSString stringWithFormat:@"video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
            NSURL *outURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
            __block NSURL *resVideoURL = nil;

            [mgr requestExportSessionForVideo:asset
                                      options:vOpts
                                 exportPreset:AVAssetExportPresetPassthrough
                                resultHandler:^(AVAssetExportSession *session, NSDictionary *info) {
                if (session) {
                    session.outputURL = outURL;
                    session.outputFileType = AVFileTypeMPEG4;
                    [session exportAsynchronouslyWithCompletionHandler:^{
                        if (session.status == AVAssetExportSessionStatusCompleted) {
                            resVideoURL = outURL;
                        }
                        dispatch_semaphore_signal(vSem);
                    }];
                } else {
                    dispatch_semaphore_signal(vSem);
                }
            }];

            dispatch_semaphore_wait(vSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
            if (resVideoURL) return resVideoURL;
        }
    }

    // 7. NSItemProvider (Universal iOS 13+ share sheet item)
    if ([item isKindOfClass:[NSItemProvider class]]) {
        NSItemProvider *provider = (NSItemProvider *)item;
        __block NSURL *resolved = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSArray *types = @[
            @"public.movie",
            @"public.video",
            @"public.image",
            @"public.jpeg",
            @"public.png",
            @"public.heic",
            @"public.audio",
            @"public.mp3",
            @"public.pdf",
            @"public.zip-archive",
            @"public.data",
            @"public.content",
            @"public.item"
        ];

        for (NSString *type in types) {
            if ([provider hasItemConformingToTypeIdentifier:type]) {
                [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
                    if (url && url.isFileURL) {
                        NSString *filename = url.lastPathComponent ?: [NSString stringWithFormat:@"file_%ld.bin", (long)[[NSDate date] timeIntervalSince1970]];
                        NSURL *dest = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:filename];
                        [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
                        [[NSFileManager defaultManager] copyItemAtURL:url toURL:dest error:nil];
                        resolved = dest;
                    }
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
                if (resolved) return resolved;
                break;
            }
        }

        // Fallback for UIImage in item provider
        if (!resolved && [provider canLoadObjectOfClass:[UIImage class]]) {
            [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if ([obj isKindOfClass:[UIImage class]]) {
                    NSData *data = UIImageJPEGRepresentation((UIImage *)obj, 0.95);
                    if (data) {
                        NSString *name = [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
                        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
                        [data writeToURL:tmp atomically:YES];
                        resolved = tmp;
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
            if (resolved) return resolved;
        }
    }

    // 8. Raw NSData
    if ([item isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)item;
        NSString *ext = @"bin";
        // Check magic bytes
        if (data.length > 4) {
            const uint8_t *b = (const uint8_t *)data.bytes;
            if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ext = @"jpg";
            else if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') ext = @"png";
            else if (b[0] == '%' && b[1] == 'P' && b[2] == 'D' && b[3] == 'F') ext = @"pdf";
            else if (b[0] == 'P' && b[1] == 'K') ext = @"zip";
        }
        NSString *name = [NSString stringWithFormat:@"file_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
        [data writeToURL:tmp atomically:YES];
        return tmp;
    }

    // 9. Plain text
    if ([item isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)item dataUsingEncoding:NSUTF8StringEncoding];
        NSString *name = [NSString stringWithFormat:@"note_%ld.txt", (long)[[NSDate date] timeIntervalSince1970]];
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
        [data writeToURL:tmp atomically:YES];
        return tmp;
    }

    return nil;
}

@end

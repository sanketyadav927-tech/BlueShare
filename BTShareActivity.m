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

// ── Helper: Safe KVC extraction of underlying PHAsset ─────────────────────────
static id extractAssetFromItem(id item) {
    if (!item) return nil;
    Class PHAssetClass = NSClassFromString(@"PHAsset");
    if (PHAssetClass && [item isKindOfClass:PHAssetClass]) {
        return item;
    }

    // Unwrapping for Photos app wrappers (PUActivityItemSource, PXActivityItemSourceRecord, etc.)
    NSArray *keys = @[@"asset", @"_asset", @"selectedAsset", @"_selectedAsset", @"photo", @"_photo", @"underlyingAsset"];
    for (NSString *k in keys) {
        @try {
            id val = [item valueForKey:k];
            if (val && PHAssetClass && [val isKindOfClass:PHAssetClass]) {
                return val;
            }
        } @catch (NSException *_) {}
    }

    if ([item respondsToSelector:@selector(asset)]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id val = [item performSelector:@selector(asset)];
            #pragma clang diagnostic pop
            if (val && PHAssetClass && [val isKindOfClass:PHAssetClass]) {
                return val;
            }
        } @catch (NSException *_) {}
    }

    return nil;
}

// ── Helper: Multi-tier PHAsset to File URL exporter ───────────────────────────
static NSURL *exportAssetToFile(PHAsset *asset) {
    if (!asset) return nil;

    // Tier 1: Direct File on Disk (Instant DCIM access, 0ms)
    @try {
        NSString *path = [asset valueForKey:@"pathForOriginalFile"];
        if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
            if (sz > 0) return [NSURL fileURLWithPath:path];
        }
    } @catch (NSException *_) {}

    @try {
        NSURL *mainURL = [asset valueForKey:@"mainFileURL"];
        if (mainURL && [[NSFileManager defaultManager] fileExistsAtPath:mainURL.path]) {
            unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:mainURL.path error:nil] fileSize];
            if (sz > 0) return mainURL;
        }
    } @catch (NSException *_) {}

    // Tier 2: PHAssetResourceManager (Official Apple Photos framework file exporter)
    if (NSClassFromString(@"PHAssetResource") && NSClassFromString(@"PHAssetResourceManager")) {
        NSArray<PHAssetResource *> *resources = [PHAssetResource assetResourcesForAsset:asset];
        PHAssetResource *targetRes = nil;
        for (PHAssetResource *r in resources) {
            if (r.type == PHAssetResourceTypePhoto ||
                r.type == PHAssetResourceTypeVideo ||
                r.type == PHAssetResourceTypeFullSizePhoto ||
                r.type == PHAssetResourceTypeFullSizeVideo) {
                targetRes = r;
                break;
            }
        }
        if (!targetRes) targetRes = resources.firstObject;

        if (targetRes) {
            NSString *origName = targetRes.originalFilename;
            if (!origName || origName.length == 0) {
                origName = (asset.mediaType == PHAssetMediaTypeVideo) ? @"video.mp4" : @"photo.jpg";
            }
            NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%lu_%@", (unsigned long)[[NSDate date] timeIntervalSince1970], origName]];
            NSURL *destURL = [NSURL fileURLWithPath:destPath];
            [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];

            PHAssetResourceRequestOptions *rOpts = [PHAssetResourceRequestOptions new];
            rOpts.networkAccessAllowed = YES;

            dispatch_semaphore_t rSem = dispatch_semaphore_create(0);
            __block BOOL rSuccess = NO;
            [[PHAssetResourceManager defaultManager] writeDataForAssetResource:targetRes
                                                                        toFile:destURL
                                                                       options:rOpts
                                                             completionHandler:^(NSError * _Nullable error) {
                if (!error && [[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
                    rSuccess = YES;
                }
                dispatch_semaphore_signal(rSem);
            }];
            dispatch_semaphore_wait(rSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)));
            if (rSuccess) return destURL;
        }
    }

    // Tier 3: requestContentEditingInputWithOptions (Retrieve full-size URL)
    PHContentEditingInputRequestOptions *editOpts = [PHContentEditingInputRequestOptions new];
    editOpts.networkAccessAllowed = YES;
    dispatch_semaphore_t eSem = dispatch_semaphore_create(0);
    __block NSURL *eURL = nil;
    [asset requestContentEditingInputWithOptions:editOpts completionHandler:^(PHContentEditingInput * _Nullable input, NSDictionary * _Nonnull info) {
        if (input.fullSizeImageURL && [[NSFileManager defaultManager] fileExistsAtPath:input.fullSizeImageURL.path]) {
            eURL = input.fullSizeImageURL;
        } else if (input.avAsset && [input.avAsset isKindOfClass:[AVURLAsset class]]) {
            NSURL *u = [(AVURLAsset *)input.avAsset URL];
            if (u && [[NSFileManager defaultManager] fileExistsAtPath:u.path]) {
                eURL = u;
            }
        }
        dispatch_semaphore_signal(eSem);
    }];
    dispatch_semaphore_wait(eSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    if (eURL) return eURL;

    // Tier 4: PHImageManager raw image data extraction with HEIC transcode to JPEG
    PHImageManager *mgr = [PHImageManager defaultManager];
    if (asset.mediaType == PHAssetMediaTypeImage) {
        PHImageRequestOptions *opts = [PHImageRequestOptions new];
        opts.synchronous = YES;
        opts.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
        opts.networkAccessAllowed = YES;

        __block NSURL *imgURL = nil;
        [mgr requestImageDataAndOrientationForAsset:asset
                                           options:opts
                                     resultHandler:^(NSData *imageData, NSString *dataUTI, CGImagePropertyOrientation orientation, NSDictionary *info) {
            if (imageData && imageData.length > 0) {
                NSData *finalData = imageData;
                NSString *ext = @"jpg";
                // Transcode HEIC to JPEG so Android can view & save to gallery immediately
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

                NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"photo_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext]];
                if ([finalData writeToFile:destPath atomically:YES]) {
                    imgURL = [NSURL fileURLWithPath:destPath];
                }
            }
        }];
        if (imgURL) return imgURL;

        // Tier 5: High-resolution UIImage rendering fallback
        [mgr requestImageForAsset:asset
                       targetSize:CGSizeMake(4000, 4000)
                      contentMode:PHImageContentModeAspectFit
                          options:opts
                    resultHandler:^(UIImage *result, NSDictionary *info) {
            if (result) {
                NSData *jpg = UIImageJPEGRepresentation(result, 0.95);
                if (jpg) {
                    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
                    if ([jpg writeToFile:destPath atomically:YES]) {
                        imgURL = [NSURL fileURLWithPath:destPath];
                    }
                }
            }
        }];
        if (imgURL) return imgURL;
    } else if (asset.mediaType == PHAssetMediaTypeVideo) {
        // Tier 6: Video Export via AVAssetExportSession (.mp4)
        PHVideoRequestOptions *vOpts = [PHVideoRequestOptions new];
        vOpts.networkAccessAllowed = YES;
        vOpts.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;

        dispatch_semaphore_t vSem = dispatch_semaphore_create(0);
        NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]]];
        NSURL *outURL = [NSURL fileURLWithPath:destPath];
        __block NSURL *resVideoURL = nil;

        [mgr requestExportSessionForVideo:asset
                                  options:vOpts
                             exportPreset:AVAssetExportPresetPassthrough
                            resultHandler:^(AVAssetExportSession *session, NSDictionary *info) {
            if (session) {
                session.outputURL = outURL;
                session.outputFileType = AVFileTypeMPEG4;
                [session exportAsynchronouslyWithCompletionHandler:^{
                    if (session.status == AVAssetExportSessionStatusCompleted &&
                        [[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
                        resVideoURL = outURL;
                    }
                    dispatch_semaphore_signal(vSem);
                }];
            } else {
                dispatch_semaphore_signal(vSem);
            }
        }];
        dispatch_semaphore_wait(vSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        if (resVideoURL) return resVideoURL;
    }
    return nil;
}

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
        }
    }

    // Directly present Instant Share view controller (QR Code interface)
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

    // 1. Check for PHAsset or wrappers in Photos app (PUActivityItemSource, PXActivityItemSourceRecord)
    PHAsset *asset = extractAssetFromItem(item);
    if (asset) {
        NSURL *u = exportAssetToFile(asset);
        if (u) return u;
    }

    // 2. Direct file URL (Files app, WhatsApp, Safari downloads, Mail attachments, etc.)
    if ([item isKindOfClass:[NSURL class]]) {
        NSURL *url = (NSURL *)item;
        if (url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            return url;
        }
    }

    // 3. UIActivityItemSource protocol unwrapping
    if ([item respondsToSelector:@selector(activityViewController:itemForActivityType:)]) {
        @try {
            id inner = ((id (*)(id, SEL, id, id))objc_msgSend)(item, @selector(activityViewController:itemForActivityType:), nil, self.activityType);
            if (inner && inner != item) {
                NSURL *u = [self resolveItemToFileURL:inner];
                if (u) return u;
            }
        } @catch (NSException *_) {}
    }

    // 4. UIActivityItemSource placeholder unwrapping
    if ([item respondsToSelector:@selector(activityViewControllerPlaceholderItem:)]) {
        @try {
            id ph = ((id (*)(id, SEL, id))objc_msgSend)(item, @selector(activityViewControllerPlaceholderItem:), nil);
            if (ph && ph != item) {
                NSURL *u = [self resolveItemToFileURL:ph];
                if (u) return u;
            }
        } @catch (NSException *_) {}
    }

    // 5. UIImage (Camera, Screenshots, Safari image, Markup)
    if ([item isKindOfClass:[UIImage class]]) {
        UIImage *img = (UIImage *)item;
        NSData *data = UIImageJPEGRepresentation(img, 0.95) ?: UIImagePNGRepresentation(img);
        if (data) {
            NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
            if ([data writeToFile:destPath atomically:YES]) {
                return [NSURL fileURLWithPath:destPath];
            }
        }
    }

    // 6. NSItemProvider (Universal iOS 13+ share sheet item)
    if ([item isKindOfClass:[NSItemProvider class]]) {
        NSItemProvider *provider = (NSItemProvider *)item;

        for (NSString *type in provider.registeredTypeIdentifiers) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSURL *resolved = nil;

            [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
                if (url && url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                    NSString *filename = url.lastPathComponent ?: [NSString stringWithFormat:@"file_%ld.bin", (long)[[NSDate date] timeIntervalSince1970]];
                    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%ld_%@", (long)[[NSDate date] timeIntervalSince1970], filename]];
                    NSURL *destURL = [NSURL fileURLWithPath:destPath];
                    [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
                    if ([[NSFileManager defaultManager] copyItemAtURL:url toURL:destURL error:nil]) {
                        resolved = destURL;
                    }
                }
                dispatch_semaphore_signal(sem);
            }];

            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
            if (resolved) return resolved;
        }

        // Fallback for UIImage in item provider
        if ([provider canLoadObjectOfClass:[UIImage class]]) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSURL *resolved = nil;
            [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if ([obj isKindOfClass:[UIImage class]]) {
                    NSData *data = UIImageJPEGRepresentation((UIImage *)obj, 0.95);
                    if (data) {
                        NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
                        if ([data writeToFile:destPath atomically:YES]) {
                            resolved = [NSURL fileURLWithPath:destPath];
                        }
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
            if (resolved) return resolved;
        }
    }

    // 7. Raw NSData
    if ([item isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)item;
        NSString *ext = @"bin";
        if (data.length > 4) {
            const uint8_t *b = (const uint8_t *)data.bytes;
            if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ext = @"jpg";
            else if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') ext = @"png";
            else if (b[0] == '%' && b[1] == 'P' && b[2] == 'D' && b[3] == 'F') ext = @"pdf";
            else if (b[0] == 'P' && b[1] == 'K') ext = @"zip";
        }
        NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"file_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext]];
        if ([data writeToFile:destPath atomically:YES]) {
            return [NSURL fileURLWithPath:destPath];
        }
    }

    // 8. Plain text / Web Link
    if ([item isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)item;
        NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
        NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"note_%ld.txt", (long)[[NSDate date] timeIntervalSince1970]]];
        if ([data writeToFile:destPath atomically:YES]) {
            return [NSURL fileURLWithPath:destPath];
        }
    }

    return nil;
}

@end

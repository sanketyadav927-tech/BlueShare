// DevicePickerViewController.h
// Scans for nearby BlueShare peers and lets the user pick one to send to.
// Hosts an unsandboxed local HTTP server for Instant Share to Android.
// Author: Sanket Yadav

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSSimpleHTTPServer : NSObject
+ (instancetype)sharedServer;
- (void)startListening;
- (NSString *)startWithFileURLs:(NSArray<NSURL *> *)fileURLs errorReason:(NSString **)outError;
- (void)stop;
- (NSString *)localIPAddress;
- (NSString *)connectionType;
@end

@interface DevicePickerViewController : UIViewController

/// File URLs to send (one or more files).
- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)fileURLs;

/// Called with YES on completion, NO on cancellation.
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL success);

@end

NS_ASSUME_NONNULL_END

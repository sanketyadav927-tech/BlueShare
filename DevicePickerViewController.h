// DevicePickerViewController.h
// Scans for nearby BlueShare peers and lets the user pick one to send to.

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

@interface DevicePickerViewController : UITableViewController

/// File URLs to send (one or more files).
- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)fileURLs NS_DESIGNATED_INITIALIZER;

// Override superclass designated initializer to satisfy compiler chain requirement
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil NS_DESIGNATED_INITIALIZER;

/// Called with YES on successful transfer, NO on failure/cancellation.
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL success);

@end

NS_ASSUME_NONNULL_END

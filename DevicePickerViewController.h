// DevicePickerViewController.h
// Scans for nearby BlueShare peers and lets the user pick one to send to.

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

@interface DevicePickerViewController : UITableViewController

/// File URLs to send (one or more files).
- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)fileURLs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Called with YES on successful transfer, NO on failure/cancellation.
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL success);

@end

NS_ASSUME_NONNULL_END

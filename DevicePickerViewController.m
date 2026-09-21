// DevicePickerViewController.m
// Scans for nearby BlueShare peers, shows them in a table, and drives the
// sender-side transfer with a live progress HUD.

#import "DevicePickerViewController.h"
#import "TransferManager.h"

// ── Simple peer model ─────────────────────────────────────────────────────────
@interface BSPeer : NSObject
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, copy)   NSString     *displayName;
@end
@implementation BSPeer @end

// ── Progress HUD (lightweight, no external deps) ──────────────────────────────
@interface BSProgressHUD : UIView
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UILabel        *label;
+ (instancetype)showInView:(UIView *)parent;
- (void)setProgress:(float)p;
- (void)dismiss;
@end

@implementation BSProgressHUD
+ (instancetype)showInView:(UIView *)parent {
    BSProgressHUD *hud = [[BSProgressHUD alloc] initWithFrame:parent.bounds];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
    card.layer.cornerRadius = 18;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [hud addSubview:card];

    UILabel *lbl = [UILabel new];
    lbl.text = @"Sending…";
    lbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.tintColor = [UIColor systemBlueColor];
    bar.progress  = 0;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    [card.contentView addSubview:lbl];
    [card.contentView addSubview:bar];
    hud.bar   = bar;
    hud.label = lbl;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:hud.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],
        [card.widthAnchor  constraintEqualToConstant:260],
        [card.heightAnchor constraintEqualToConstant:100],

        [lbl.topAnchor    constraintEqualToAnchor:card.contentView.topAnchor  constant:20],
        [lbl.centerXAnchor constraintEqualToAnchor:card.contentView.centerXAnchor],

        [bar.topAnchor    constraintEqualToAnchor:lbl.bottomAnchor    constant:16],
        [bar.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor  constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20],
    ]];

    [parent addSubview:hud];
    return hud;
}
- (void)setProgress:(float)p {
    self.label.text = [NSString stringWithFormat:@"Sending… %d%%", (int)(p * 100)];
    [self.bar setProgress:p animated:YES];
}
- (void)dismiss {
    [UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; }
                     completion:^(BOOL _){ [self removeFromSuperview]; }];
}
@end

// ── DevicePickerViewController ────────────────────────────────────────────────
@interface DevicePickerViewController () <BSTransferManagerDelegate>
@property (nonatomic, strong) NSArray<NSURL *>  *fileURLs;
@property (nonatomic, strong) NSMutableArray<BSPeer *> *peers;
@property (nonatomic, strong) UIActivityIndicatorView  *spinner;
@property (nonatomic, strong) BSProgressHUD            *hud;
@property (nonatomic, strong) UILabel                  *emptyLabel;
@end

@implementation DevicePickerViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _fileURLs = @[];
        _peers    = [NSMutableArray new];
    }
    return self;
}

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        _fileURLs = @[];
        _peers    = [NSMutableArray new];
    }
    return self;
}

- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)fileURLs {
    if ((self = [self initWithStyle:UITableViewStyleInsetGrouped])) {
        _fileURLs = [fileURLs copy];
    }
    return self;
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Send via Bluetooth";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self action:@selector(didTapCancel)];

    // Spinner in nav bar right
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.spinner];

    // Empty state label
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"Scanning for nearby Bluetooth devices…\n\nMake sure Bluetooth is turned on and discoverable on the other device.";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.tableView.backgroundView = self.emptyLabel;

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"PeerCell"];

    // Pull to refresh
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(didPullToRefresh:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    // Start scanning
    [BSTransferManager sharedManager].delegate = self;
    [[BSTransferManager sharedManager] startScanningForPeers];
}

- (void)didPullToRefresh:(UIRefreshControl *)rc {
    [self.peers removeAllObjects];
    [self.tableView reloadData];
    [[BSTransferManager sharedManager] stopScanning];
    [[BSTransferManager sharedManager] startScanningForPeers];
    [rc endRefreshing];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [[BSTransferManager sharedManager] stopScanning];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)didTapCancel {
    [[BSTransferManager sharedManager] stopScanning];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.completionHandler) self.completionHandler(NO);
    }];
}

// ── BSTransferManagerDelegate (sender side) ───────────────────────────────────

- (void)transferManager:(id)mgr didUpdateBluetoothState:(CBManagerState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state == CBManagerStatePoweredOff) {
            self.emptyLabel.text = @"Bluetooth is Turned Off ⚠️\n\nPlease turn on Bluetooth in Settings or Control Center to scan.";
            [self.spinner stopAnimating];
        } else if (state == CBManagerStateUnauthorized) {
            self.emptyLabel.text = @"Bluetooth Unauthorized ⚠️\n\nPlease check Bluetooth permissions in Settings.";
            [self.spinner stopAnimating];
        } else if (state == CBManagerStateUnsupported) {
            self.emptyLabel.text = @"Bluetooth is not supported on this device.";
            [self.spinner stopAnimating];
        } else if (state == CBManagerStatePoweredOn) {
            self.emptyLabel.text = @"Scanning for nearby Bluetooth devices…\n\nMake sure Bluetooth is turned on and discoverable on the other device.";
            [self.spinner startAnimating];
        }
    });
}

// ── UITableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    self.tableView.backgroundView.hidden = (self.peers.count > 0);
    return (NSInteger)self.peers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"PeerCell" forIndexPath:ip];
    BSPeer *peer = self.peers[ip.row];

    cell.textLabel.text = peer.displayName;
    if ([peer.displayName localizedCaseInsensitiveContainsString:@"android"] ||
        [peer.displayName localizedCaseInsensitiveContainsString:@"samsung"] ||
        [peer.displayName localizedCaseInsensitiveContainsString:@"pixel"] ||
        [peer.displayName localizedCaseInsensitiveContainsString:@"xiaomi"] ||
        [peer.displayName localizedCaseInsensitiveContainsString:@"redmi"] ||
        [peer.displayName localizedCaseInsensitiveContainsString:@"oneplus"]) {
        cell.imageView.image = [UIImage systemImageNamed:@"candybarphone"];
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"iphone"];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.peers.count > 0 ? @"Nearby Devices" : nil;
}

// ── UITableViewDelegate ───────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    BSPeer *peer = self.peers[ip.row];

    // Confirm dialog
    NSString *msg = [NSString stringWithFormat:
        @"Send %lu file(s) to %@?", (unsigned long)self.fileURLs.count, peer.displayName];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Send File"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Send" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        [self startSendingToPeer:peer];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── Transfer ──────────────────────────────────────────────────────────────────

- (void)startSendingToPeer:(BSPeer *)peer {
    self.hud = [BSProgressHUD showInView:self.navigationController.view];
    // For simplicity send the first file; you can loop for multi-file
    [[BSTransferManager sharedManager] sendFileAtURL:self.fileURLs.firstObject
                                              toPeer:peer.peripheral];
}

// ── BSTransferManagerDelegate (sender side) ───────────────────────────────────

- (void)transferManager:(id)mgr didDiscoverPeer:(CBPeripheral *)peer name:(NSString *)name {
    for (BSPeer *existing in self.peers) {
        if ([existing.peripheral.identifier isEqual:peer.identifier]) {
            return;
        }
    }
    BSPeer *p = [BSPeer new];
    p.peripheral   = peer;
    p.displayName  = (name && name.length > 0) ? name : @"Nearby iPhone";
    [self.peers addObject:p];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

- (void)transferManager:(id)mgr sendProgress:(float)progress {
    [self.hud setProgress:progress];
}

- (void)transferManager:(id)mgr didFinishSendingToPeer:(CBPeripheral *)peer {
    [self.hud dismiss];
    UIAlertController *done = [UIAlertController
        alertControllerWithTitle:@"Sent! ✅"
                         message:@"The file was delivered successfully."
                  preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *_) {
        [self dismissViewControllerAnimated:YES completion:^{
            if (self.completionHandler) self.completionHandler(YES);
        }];
    }]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)transferManager:(id)mgr sendDidFailWithError:(NSError *)error {
    [self.hud dismiss];
    UIAlertController *err = [UIAlertController
        alertControllerWithTitle:@"Transfer Failed"
                         message:error.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:err animated:YES completion:nil];
}

@end

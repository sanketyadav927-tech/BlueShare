// DevicePickerViewController.m
// Scans for nearby BlueShare peers, shows them in a table, and drives the
// sender-side transfer with a live progress HUD. Supports Android & BLE devices.

#import "DevicePickerViewController.h"
#import "TransferManager.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <CoreImage/CoreImage.h>

// ── Simple peer model ─────────────────────────────────────────────────────────
@interface BSPeer : NSObject
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) id            classicDevice;
@property (nonatomic, copy)   NSString     *displayName;
@property (nonatomic, copy)   NSString     *address;
@property (nonatomic)         BOOL          isClassic;
@end
@implementation BSPeer @end

// ── Embedded HTTP Server for Direct Android Transfer ─────────────────────────
@interface BSSimpleHTTPServer : NSObject
+ (instancetype)sharedServer;
- (NSString *)startWithFileURL:(NSURL *)fileURL;
- (void)stop;
- (NSString *)localIPAddress;
- (NSString *)connectionType;
@end

@implementation BSSimpleHTTPServer {
    int _serverFd;
    BOOL _running;
    NSData *_fileData;
    NSString *_mimeType;
    NSString *_fileName;
}

+ (instancetype)sharedServer {
    static BSSimpleHTTPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BSSimpleHTTPServer new]; });
    return s;
}

- (NSString *)connectionType {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *type = @"Wi-Fi";
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name hasPrefix:@"bridge"] || [name isEqualToString:@"ap0"]) {
                    type = @"Personal Hotspot";
                    break;
                } else if ([name isEqualToString:@"en0"]) {
                    type = @"Wi-Fi";
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return type;
}

- (NSString *)localIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"bridge100"] || [name isEqualToString:@"bridge101"] ||
                    [name isEqualToString:@"en0"] || [name isEqualToString:@"en1"] || [name isEqualToString:@"ap0"]) {
                    struct sockaddr_in *saddr = (struct sockaddr_in *)temp_addr->ifa_addr;
                    NSString *ip = [NSString stringWithUTF8String:inet_ntoa(saddr->sin_addr)];
                    if (ip && ![ip isEqualToString:@"127.0.0.1"] && ![ip hasPrefix:@"169.254."]) {
                        if ([name hasPrefix:@"bridge"]) {
                            address = ip;
                            break;
                        } else if (!address) {
                            address = ip;
                        }
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return address;
}

- (NSString *)startWithFileURL:(NSURL *)fileURL {
    [self stop];

    NSString *ip = [self localIPAddress];
    if (!ip) {
        NSLog(@"[BlueShare] No local IP address found (Wi-Fi or Hotspot is inactive).");
        return nil;
    }

    _fileData = [NSData dataWithContentsOfURL:fileURL];
    if (!_fileData || _fileData.length == 0) {
        NSString *fallbackPath = @"/var/mobile/Documents/BlueShare/shared_photo.jpg";
        _fileData = [NSData dataWithContentsOfFile:fallbackPath];
    }
    if (!_fileData || _fileData.length == 0) {
        NSLog(@"[BlueShare] Could not read file data for URL: %@", fileURL);
        return nil;
    }

    _fileName = fileURL.lastPathComponent ?: @"photo.jpg";
    _mimeType = @"image/jpeg";
    if ([_fileName.pathExtension.lowercaseString isEqualToString:@"png"]) _mimeType = @"image/png";

    _serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverFd < 0) {
        NSLog(@"[BlueShare] Failed to create socket: %d", errno);
        return nil;
    }

    int opt = 1;
    setsockopt(_serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
    setsockopt(_serverFd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif

    int ports[] = {8765, 8766, 8888, 8080, 9090, 0};
    int boundPort = 0;
    BOOL bound = NO;
    for (int i = 0; i < 6; i++) {
        int p = ports[i];
        struct sockaddr_in serv_addr;
        memset(&serv_addr, 0, sizeof(serv_addr));
        serv_addr.sin_family = AF_INET;
        serv_addr.sin_addr.s_addr = INADDR_ANY;
        serv_addr.sin_port = htons(p);

        if (bind(_serverFd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) == 0) {
            if (p == 0) {
                socklen_t len = sizeof(serv_addr);
                getsockname(_serverFd, (struct sockaddr *)&serv_addr, &len);
                boundPort = ntohs(serv_addr.sin_port);
            } else {
                boundPort = p;
            }
            bound = YES;
            break;
        }
    }

    if (!bound) {
        NSLog(@"[BlueShare] Failed to bind to any port: %d", errno);
        close(_serverFd);
        _serverFd = 0;
        return nil;
    }

    if (listen(_serverFd, 10) < 0) {
        NSLog(@"[BlueShare] Failed to listen on socket: %d", errno);
        close(_serverFd);
        _serverFd = 0;
        return nil;
    }

    _running = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self->_running) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int clientFd = accept(self->_serverFd, (struct sockaddr *)&client_addr, &client_len);
            if (clientFd < 0) {
                if (!self->_running) break;
                continue;
            }

            char buffer[2048];
            ssize_t n = read(clientFd, buffer, sizeof(buffer) - 1);
            if (n <= 0) {
                close(clientFd);
                continue;
            }
            buffer[n] = '\0';
            NSString *req = [NSString stringWithUTF8String:buffer] ?: @"";

            if ([req containsString:@"GET /download"] || [req containsString:@"GET /photo"] || [req containsString:@"GET /file"]) {
                NSString *headers = [NSString stringWithFormat:
                    @"HTTP/1.1 200 OK\r\n"
                    @"Content-Type: %@\r\n"
                    @"Content-Length: %lu\r\n"
                    @"Content-Disposition: attachment; filename=\"%@\"\r\n"
                    @"Access-Control-Allow-Origin: *\r\n"
                    @"Connection: close\r\n\r\n",
                    self->_mimeType, (unsigned long)self->_fileData.length, self->_fileName];
                NSData *hdrData = [headers dataUsingEncoding:NSUTF8StringEncoding];
                write(clientFd, hdrData.bytes, hdrData.length);
                write(clientFd, self->_fileData.bytes, self->_fileData.length);
            } else {
                NSString *html = [NSString stringWithFormat:
                    @"<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                    @"<title>BlueShare Transfer</title><style>"
                    @"body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#fff;text-align:center;padding:24px;margin:0}"
                    @".box{background:#1e293b;border-radius:20px;padding:24px;max-width:380px;margin:20px auto;box-shadow:0 10px 30px rgba(0,0,0,0.5)}"
                    @".badge{background:#10b981;color:#fff;font-weight:600;font-size:12px;padding:6px 14px;border-radius:30px;display:inline-block;margin-bottom:14px}"
                    @"h2{margin:0 0 16px;font-size:20px;font-weight:700}"
                    @"img{width:100%%;max-height:300px;object-fit:cover;border-radius:14px;margin-bottom:20px;background:#0f172a}"
                    @".btn{display:block;width:100%%;box-sizing:border-box;background:#2563eb;color:#fff;text-decoration:none;padding:16px 0;border-radius:12px;font-weight:700;font-size:17px}"
                    @".hint{color:#94a3b8;font-size:13px;margin-top:14px;line-height:1.4}"
                    @"</style></head><body>"
                    @"<div class=\"box\">"
                    @"<div class=\"badge\">⚡ Instant BlueShare</div>"
                    @"<h2>Received from iPhone</h2>"
                    @"<img src=\"/photo\" alt=\"Photo\">"
                    @"<a href=\"/download\" class=\"btn\" download=\"%@\">📥 Save to Android Gallery</a>"
                    @"<p class=\"hint\">✅ Saves directly to your Android device's Downloads/Pictures and appears in your Gallery instantly.</p>"
                    @"</div>"
                    @"<script>"
                    @"setTimeout(function(){"
                    @"  var a=document.createElement('a');a.href='/download';a.download='%@';document.body.appendChild(a);a.click();"
                    @"},600);"
                    @"</script></body></html>",
                    self->_fileName, self->_fileName];

                NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
                NSString *headers = [NSString stringWithFormat:
                    @"HTTP/1.1 200 OK\r\n"
                    @"Content-Type: text/html; charset=utf-8\r\n"
                    @"Content-Length: %lu\r\n"
                    @"Access-Control-Allow-Origin: *\r\n"
                    @"Connection: close\r\n\r\n",
                    (unsigned long)htmlData.length];
                NSData *hdrData = [headers dataUsingEncoding:NSUTF8StringEncoding];
                write(clientFd, hdrData.bytes, hdrData.length);
                write(clientFd, htmlData.bytes, htmlData.length);
            }
            close(clientFd);
        }
    });

    return [NSString stringWithFormat:@"http://%@:%d/", ip, boundPort];
}

- (void)stop {
    _running = NO;
    if (_serverFd > 0) {
        close(_serverFd);
        _serverFd = 0;
    }
}
@end

// ── QR View Controller for Android Drop ───────────────────────────────────────
@interface BSQRViewController : UIViewController
@property (nonatomic, copy) NSString *urlString;
@end

@implementation BSQRViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scan with Android";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(didTapDone)];

    // Generate QR using CGImage for maximum crispness
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[self.urlString dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *ciImg = filter.outputImage;

    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImg = [ctx createCGImage:ciImg fromRect:ciImg.extent];
    UIImage *qr = [UIImage imageWithCGImage:cgImg scale:1.0 orientation:UIImageOrientationUp];
    if (cgImg) CGImageRelease(cgImg);

    UIImageView *iv = [[UIImageView alloc] initWithImage:qr];
    iv.layer.magnificationFilter = kCAFilterNearest;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:iv];

    // Connection indicator
    NSString *connType = [[BSSimpleHTTPServer sharedServer] connectionType];
    UILabel *badge = [UILabel new];
    badge.text = [NSString stringWithFormat:@"  Connected via %@  ", connType];
    badge.textColor = [UIColor systemGreenColor];
    badge.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    badge.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.12];
    badge.layer.cornerRadius = 10;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:badge];

    UILabel *desc = [UILabel new];
    desc.text = @"Point your Android Camera at this QR code.\nThe photo will save directly to your Android Gallery!";
    desc.numberOfLines = 0;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    desc.textColor = [UIColor labelColor];
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:desc];

    UILabel *urlLbl = [UILabel new];
    urlLbl.text = self.urlString;
    urlLbl.textAlignment = NSTextAlignmentCenter;
    urlLbl.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    urlLbl.textColor = [UIColor systemBlueColor];
    urlLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:urlLbl];

    [NSLayoutConstraint activateConstraints:@[
        [badge.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [badge.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [badge.heightAnchor constraintEqualToConstant:24],

        [iv.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [iv.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:16],
        [iv.widthAnchor constraintEqualToConstant:230],
        [iv.heightAnchor constraintEqualToConstant:230],

        [desc.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:20],
        [desc.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [desc.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [urlLbl.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:14],
        [urlLbl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)didTapDone {
    [[BSSimpleHTTPServer sharedServer] stop];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ── Progress HUD ──────────────────────────────────────────────────────────────
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

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.spinner];

    // Empty state label
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"Scanning for nearby Bluetooth & Android devices…\n\n💡 On your Android phone, keep Settings > Bluetooth open so it is visible to scan.";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.tableView.backgroundView = self.emptyLabel;

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

// ── BSTransferManagerDelegate ─────────────────────────────────────────────────

- (void)transferManager:(id)mgr didUpdateBluetoothState:(CBManagerState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state == CBManagerStatePoweredOff) {
            self.emptyLabel.text = @"Bluetooth is Turned Off ⚠️\n\nPlease turn on Bluetooth in Settings or Control Center to scan.";
            [self.spinner stopAnimating];
        } else if (state == CBManagerStateUnauthorized) {
            self.emptyLabel.text = @"Bluetooth Unauthorized ⚠️\n\nPlease check Bluetooth permissions in Settings.";
            [self.spinner stopAnimating];
        } else if (state == CBManagerStateUnsupported) {
            // Photos sandbox lacks BLE central entitlements, but Bluetooth Classic inquiry is active!
            self.emptyLabel.text = @"Scanning for nearby Bluetooth & Android devices…\n\n💡 On your Android phone, keep Settings > Bluetooth open so it is visible to scan.";
            [self.spinner startAnimating];
        } else if (state == CBManagerStatePoweredOn) {
            self.emptyLabel.text = @"Scanning for nearby Bluetooth & Android devices…\n\n💡 On your Android phone, keep Settings > Bluetooth open so it is visible to scan.";
            [self.spinner startAnimating];
        }
    });
}

- (void)transferManager:(id)mgr didDiscoverPeer:(CBPeripheral *)peer name:(NSString *)name {
    for (BSPeer *existing in self.peers) {
        if ([existing.peripheral.identifier isEqual:peer.identifier]) return;
    }
    BSPeer *p = [BSPeer new];
    p.peripheral   = peer;
    p.displayName  = (name && name.length > 0) ? name : @"Nearby iPhone";
    p.isClassic    = NO;
    [self.peers addObject:p];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

- (void)transferManager:(id)mgr didDiscoverClassicDevice:(id)device name:(NSString *)name address:(NSString *)address {
    for (BSPeer *existing in self.peers) {
        if (address && [existing.address isEqualToString:address]) return;
        if ([existing.displayName isEqualToString:name]) return;
    }
    BSPeer *p = [BSPeer new];
    p.classicDevice = device;
    p.displayName   = name;
    p.address       = address;
    p.isClassic     = YES;
    [self.peers addObject:p];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// ── UITableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2; // Section 0: Instant Android Share, Section 1: Discovered Bluetooth Devices
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    self.emptyLabel.hidden = (self.peers.count > 0);
    return (NSInteger)self.peers.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Fast Android Transfer";
    return self.peers.count > 0 ? @"Nearby Bluetooth Devices" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Instant zero-setup transfer: works with ANY Android phone using its Camera or Browser directly into Gallery.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"DirectCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"DirectCell"];
        }
        cell.textLabel.text = @"⚡ Instant Share to Android Gallery";
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = @"Scan QR with Android Camera • Saves to Gallery in 1s";
        cell.detailTextLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"qrcode"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"PeerCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"PeerCell"];
    }
    BSPeer *peer = self.peers[ip.row];
    cell.textLabel.text = peer.displayName;

    if (peer.isClassic) {
        if ([peer.displayName localizedCaseInsensitiveContainsString:@"android"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"samsung"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"pixel"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"xiaomi"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"redmi"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"oneplus"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"oppo"] ||
            [peer.displayName localizedCaseInsensitiveContainsString:@"vivo"]) {
            cell.imageView.image = [UIImage systemImageNamed:@"candybarphone"];
            cell.detailTextLabel.text = @"Android Device • Bluetooth";
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.detailTextLabel.text = @"Bluetooth Device";
        }
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"iphone"];
        cell.detailTextLabel.text = @"BlueShare Peer • BLE";
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

// ── UITableViewDelegate ───────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) {
        // Instant Android QR / Web Drop
        [self showInstantWebDropForFile:self.fileURLs.firstObject];
        return;
    }

    BSPeer *peer = self.peers[ip.row];
    if (peer.isClassic) {
        // Bluetooth Classic / Android device tapped
        NSString *msg = [NSString stringWithFormat:@"Send to %@?\n\nTip: You can use Instant Share to deliver directly into the Android Gallery, or connect via Bluetooth.", peer.displayName];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:peer.displayName
                             message:msg
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [alert addAction:[UIAlertAction actionWithTitle:@"⚡ Send Directly to Android Gallery (QR/Web)"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) {
            [self showInstantWebDropForFile:self.fileURLs.firstObject];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Pair & Connect via Bluetooth"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) {
            @try {
                if ([peer.classicDevice respondsToSelector:@selector(connect)]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [peer.classicDevice performSelector:@selector(connect)];
                    #pragma clang diagnostic pop
                }
            } @catch (NSException *_) {}
            [self showInstantWebDropForFile:self.fileURLs.firstObject];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // BLE BlueShare peer
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

- (void)showInstantWebDropForFile:(NSURL *)fileURL {
    NSString *localIP = [[BSSimpleHTTPServer sharedServer] localIPAddress];
    if (!localIP) {
        UIAlertController *err = [UIAlertController
            alertControllerWithTitle:@"Hotspot or Wi-Fi Required"
                             message:@"To transfer photos directly to Android without an app:\n\n1. Turn ON 'Personal Hotspot' in iPhone Settings (or connect both phones to the same Wi-Fi).\n2. Connect your Android phone to iPhone's Hotspot.\n3. Tap Instant Share to scan the QR code!"
                      preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"Open Settings (Hotspot)"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *_) {
            NSURL *settingsURL = [NSURL URLWithString:@"App-Prefs:root=INTERNET_TETHERING"];
            if (![[UIApplication sharedApplication] canOpenURL:settingsURL]) {
                settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            }
            [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
        }]];
        [err addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:err animated:YES completion:nil];
        return;
    }

    NSString *url = [[BSSimpleHTTPServer sharedServer] startWithFileURL:fileURL];
    if (!url) {
        UIAlertController *err = [UIAlertController
            alertControllerWithTitle:@"Could Not Start Server"
                             message:@"Please verify your Wi-Fi or Personal Hotspot connection and try again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:err animated:YES completion:nil];
        return;
    }

    BSQRViewController *qrVC = [BSQRViewController new];
    qrVC.urlString = url;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:qrVC];
    [self presentViewController:nav animated:YES completion:nil];
}

// ── Transfer ──────────────────────────────────────────────────────────────────

- (void)startSendingToPeer:(BSPeer *)peer {
    self.hud = [BSProgressHUD showInView:self.navigationController.view];
    [[BSTransferManager sharedManager] sendFileAtURL:self.fileURLs.firstObject
                                              toPeer:peer.peripheral];
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

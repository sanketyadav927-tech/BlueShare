// TransferManager.m
// Full CoreBluetooth implementation for BlueShare peer-to-peer file transfer.

#import "TransferManager.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <objc/message.h>

// ── UUIDs ────────────────────────────────────────────────────────────────────
NSString *const kBSServiceUUID      = @"BA5E5001-F96A-4D21-9C2B-3A1D8E4F0123";
NSString *const kBSMetadataCharUUID = @"BA5E5002-F96A-4D21-9C2B-3A1D8E4F0123";
NSString *const kBSDataCharUUID     = @"BA5E5003-F96A-4D21-9C2B-3A1D8E4F0123";
NSString *const kBSAckCharUUID      = @"BA5E5004-F96A-4D21-9C2B-3A1D8E4F0123";
NSString *const kBSControlCharUUID  = @"BA5E5005-F96A-4D21-9C2B-3A1D8E4F0123";

static const NSUInteger kChunkSize  = 512;   // bytes per BLE write packet

// ── BSTransferMetadata ────────────────────────────────────────────────────────
@implementation BSTransferMetadata

+ (BOOL)supportsSecureCoding { return YES; }

+ (nullable instancetype)fromJSON:(NSData *)json {
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (!d) return nil;
    BSTransferMetadata *m = [self new];
    m.fileName   = d[@"fileName"]   ?: @"file";
    m.mimeType   = d[@"mimeType"]   ?: @"application/octet-stream";
    m.totalBytes = [d[@"totalBytes"] unsignedIntegerValue];
    m.chunkCount = [d[@"chunkCount"] unsignedIntegerValue];
    return m;
}

- (NSData *)toJSON {
    NSDictionary *d = @{
        @"fileName":   self.fileName,
        @"mimeType":   self.mimeType,
        @"totalBytes": @(self.totalBytes),
        @"chunkCount": @(self.chunkCount),
    };
    return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
}

- (void)encodeWithCoder:(NSCoder *)c {
    [c encodeObject:self.fileName   forKey:@"f"];
    [c encodeObject:self.mimeType   forKey:@"m"];
    [c encodeInteger:(NSInteger)self.totalBytes forKey:@"s"];
    [c encodeInteger:(NSInteger)self.chunkCount forKey:@"c"];
}
- (nullable instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [super init])) {
        _fileName   = [c decodeObjectOfClass:[NSString class] forKey:@"f"];
        _mimeType   = [c decodeObjectOfClass:[NSString class] forKey:@"m"];
        _totalBytes = (NSUInteger)[c decodeIntegerForKey:@"s"];
        _chunkCount = (NSUInteger)[c decodeIntegerForKey:@"c"];
    }
    return self;
}

@end

// ── BSTransferManager ─────────────────────────────────────────────────────────
@interface BSTransferManager ()
// Central (sender)
@property (nonatomic, strong) CBCentralManager          *central;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *discoveredPeers;
@property (nonatomic, strong) CBPeripheral              *activePeer;
@property (nonatomic, strong) CBCharacteristic          *metadataChar;
@property (nonatomic, strong) CBCharacteristic          *dataChar;
@property (nonatomic, strong) CBCharacteristic          *ackChar;
@property (nonatomic, strong) CBCharacteristic          *controlChar;
@property (nonatomic) BOOL                               isScanningRequested;
@property (nonatomic, strong) id                                btClassicManager;
@property (nonatomic, strong) NSMutableArray                   *discoveredClassicAddresses;
@property (nonatomic, strong) NSTimer                          *classicPollTimer;

// Sender state
@property (nonatomic, strong) NSData                    *fileData;
@property (nonatomic, strong) BSTransferMetadata        *sendMetadata;
@property (nonatomic) NSUInteger                         sendChunkIndex;

// Peripheral (receiver)
@property (nonatomic, strong) CBPeripheralManager       *peripheral;
@property (nonatomic, strong) CBMutableService          *btService;
@property (nonatomic, strong) CBMutableCharacteristic   *rxMetadataChar;
@property (nonatomic, strong) CBMutableCharacteristic   *rxDataChar;
@property (nonatomic, strong) CBMutableCharacteristic   *rxAckChar;
@property (nonatomic, strong) CBMutableCharacteristic   *rxControlChar;

// Receiver state
@property (nonatomic, strong) BSTransferMetadata        *recvMetadata;
@property (nonatomic, strong) NSMutableData             *recvBuffer;
@property (nonatomic) NSUInteger                         recvChunkIndex;
@property (nonatomic, strong) NSString                  *incomingSenderName;
@property (nonatomic, copy)   void (^pendingAcceptBlock)(BOOL);

@end

@implementation BSTransferManager

+ (instancetype)sharedManager {
    static BSTransferManager *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _discoveredPeers = [NSMutableArray new];
        _discoveredClassicAddresses = [NSMutableArray new];

        // Load Apple's private BluetoothManager for Bluetooth Classic inquiry scan (Android, PC)
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        Class BMClass = NSClassFromString(@"BluetoothManager");
        if (BMClass && [BMClass respondsToSelector:@selector(sharedInstance)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            _btClassicManager = [BMClass performSelector:@selector(sharedInstance)];
            #pragma clang diagnostic pop
            if (_btClassicManager) {
                if ([_btClassicManager respondsToSelector:@selector(setPowered:)]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(_btClassicManager, @selector(setPowered:), YES);
                }
                if ([_btClassicManager respondsToSelector:@selector(setEnabled:)]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(_btClassicManager, @selector(setEnabled:), YES);
                }
            }
        }
    }
    return self;
}

- (CBCentralManager *)central {
    if (!_central) {
        dispatch_queue_t cq = dispatch_queue_create("com.blueshare.central", DISPATCH_QUEUE_SERIAL);
        _central = [[CBCentralManager alloc] initWithDelegate:self queue:cq];
    }
    return _central;
}

- (CBPeripheralManager *)peripheral {
    if (!_peripheral) {
        dispatch_queue_t pq = dispatch_queue_create("com.blueshare.peripheral", DISPATCH_QUEUE_SERIAL);
        _peripheral = [[CBPeripheralManager alloc] initWithDelegate:self queue:pq];
    }
    return _peripheral;
}

// ── SENDER ────────────────────────────────────────────────────────────────────

- (void)startScanningForPeers {
    self.isScanningRequested = YES;
    [self.discoveredPeers removeAllObjects];
    [self.discoveredClassicAddresses removeAllObjects];

    // 1. CoreBluetooth BLE Scan
    CBCentralManager *central = self.central;
    if (central.state == CBManagerStatePoweredOn) {
        NSLog(@"[BlueShare] Central already powered on. Starting scan now.");
        [central scanForPeripheralsWithServices:nil
                                        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    } else {
        NSLog(@"[BlueShare] Central state is %ld. Scan will auto-start once Bluetooth is powered on.", (long)central.state);
    }

    // 2. Bluetooth Classic Inquiry Scan (discovers Android phones!)
    if (self.btClassicManager) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"BluetoothDeviceDiscoveredNotification"
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"BluetoothDeviceUpdatedNotification"
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(bluetoothClassicDeviceDiscovered:)
                                                     name:@"BluetoothDeviceDiscoveredNotification"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(bluetoothClassicDeviceDiscovered:)
                                                     name:@"BluetoothDeviceUpdatedNotification"
                                                   object:nil];
        @try {
            if ([self.btClassicManager respondsToSelector:@selector(setPowered:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setPowered:), YES);
            }
            if ([self.btClassicManager respondsToSelector:@selector(setEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setEnabled:), YES);
            }

            // Start Bluetooth Classic device inquiry using correct BOOL ABI
            if ([self.btClassicManager respondsToSelector:@selector(setDeviceScanningEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setDeviceScanningEnabled:), YES);
                NSLog(@"[BlueShare] Bluetooth Classic inquiry scanning enabled (YES).");
            }
            if ([self.btClassicManager respondsToSelector:@selector(setDevicePairingEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setDevicePairingEnabled:), YES);
            }
            if ([self.btClassicManager respondsToSelector:@selector(scanForConnectableDevices:)]) {
                ((void (*)(id, SEL, unsigned int))objc_msgSend)(self.btClassicManager, @selector(scanForConnectableDevices:), 0);
            }
            if ([self.btClassicManager respondsToSelector:@selector(scanForServices:)]) {
                ((void (*)(id, SEL, unsigned int))objc_msgSend)(self.btClassicManager, @selector(scanForServices:), 0xFFFFFFFF);
            }

            // Immediately poll paired & discovered devices
            [self pollClassicDevices];

            // Periodically poll discovered devices every 1.5s
            [self.classicPollTimer invalidate];
            self.classicPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                                     target:self
                                                                   selector:@selector(pollClassicDevices)
                                                                   userInfo:nil
                                                                    repeats:YES];
        } @catch (NSException *e) {
            NSLog(@"[BlueShare] Bluetooth Classic scan error: %@", e);
        }
    }
}

- (void)stopScanning {
    self.isScanningRequested = NO;
    if (_central) {
        [_central stopScan];
    }
    [self.classicPollTimer invalidate];
    self.classicPollTimer = nil;
    if (self.btClassicManager) {
        @try {
            if ([self.btClassicManager respondsToSelector:@selector(setDeviceScanningEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setDeviceScanningEnabled:), NO);
            }
            if ([self.btClassicManager respondsToSelector:@selector(setDevicePairingEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.btClassicManager, @selector(setDevicePairingEnabled:), NO);
            }
        } @catch (NSException *_) {}
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"BluetoothDeviceDiscoveredNotification"
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"BluetoothDeviceUpdatedNotification"
                                                      object:nil];
    }
}

- (void)pollClassicDevices {
    if (!self.btClassicManager) return;
    @try {
        if ([self.btClassicManager respondsToSelector:@selector(pairedDevices)]) {
            NSArray *paired = ((NSArray *(*)(id, SEL))objc_msgSend)(self.btClassicManager, @selector(pairedDevices));
            for (id dev in paired) {
                [self processClassicDevice:dev];
            }
        }
        if ([self.btClassicManager respondsToSelector:@selector(discoveredDevices)]) {
            NSArray *discovered = ((NSArray *(*)(id, SEL))objc_msgSend)(self.btClassicManager, @selector(discoveredDevices));
            for (id dev in discovered) {
                [self processClassicDevice:dev];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[BlueShare] pollClassicDevices error: %@", e);
    }
}

- (void)bluetoothClassicDeviceDiscovered:(NSNotification *)note {
    id device = note.object;
    if (device) {
        [self processClassicDevice:device];
    }
}

- (void)processClassicDevice:(id)device {
    @try {
        NSString *name = nil;
        if ([device respondsToSelector:@selector(name)]) {
            name = ((NSString *(*)(id, SEL))objc_msgSend)(device, @selector(name));
        }
        if (!name || name.length == 0) return;

        NSString *addr = nil;
        if ([device respondsToSelector:@selector(address)]) {
            addr = ((NSString *(*)(id, SEL))objc_msgSend)(device, @selector(address));
        }

        NSString *identifier = addr ?: name;
        if ([self.discoveredClassicAddresses containsObject:identifier]) {
            return;
        }
        [self.discoveredClassicAddresses addObject:identifier];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self didDiscoverClassicDevice:device name:name address:addr];
        });
    } @catch (NSException *e) {
        NSLog(@"[BlueShare] processClassicDevice error: %@", e);
    }
}

- (void)sendFileAtURL:(NSURL *)fileURL toPeer:(CBPeripheral *)peer {
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) {
        NSError *e = [NSError errorWithDomain:@"BSError" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:@"Could not read file"}];
        [self.delegate transferManager:self sendDidFailWithError:e];
        return;
    }
    self.fileData      = data;
    self.sendChunkIndex = 0;

    BSTransferMetadata *meta = [BSTransferMetadata new];
    meta.fileName   = fileURL.lastPathComponent;
    meta.mimeType   = [self mimeTypeForURL:fileURL];
    meta.totalBytes = data.length;
    meta.chunkCount = (NSUInteger)ceil((double)data.length / kChunkSize);
    self.sendMetadata = meta;

    self.activePeer = peer;
    [self.central connectPeripheral:peer options:nil];
}

// ── CBCentralManagerDelegate ──────────────────────────────────────────────────

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@"[BlueShare] Central state updated: %ld", (long)central.state);

    if ([self.delegate respondsToSelector:@selector(transferManager:didUpdateBluetoothState:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self didUpdateBluetoothState:central.state];
        });
    }

    if (central.state == CBManagerStatePoweredOn) {
        if (self.isScanningRequested) {
            NSLog(@"[BlueShare] Central powered on. Initiating Bluetooth scan now!");
            [central scanForPeripheralsWithServices:nil
                                            options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        }
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (![self.discoveredPeers containsObject:peripheral]) {
        [self.discoveredPeers addObject:peripheral];
        NSString *name = advertisementData[CBAdvertisementDataLocalNameKey]
                      ?: peripheral.name
                      ?: @"Unknown Device";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self didDiscoverPeer:peripheral name:name];
        });
    }
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    peripheral.delegate = self;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kBSServiceUUID]]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate transferManager:self didConnectToPeer:peripheral];
    });
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate transferManager:self sendDidFailWithError:error];
    });
}

// ── CBPeripheralDelegate (sender discovers chars & writes data) ───────────────

- (void)peripheral:(CBPeripheral *)peripheral
  didDiscoverServices:(NSError *)error {
    for (CBService *svc in peripheral.services) {
        [peripheral discoverCharacteristics:@[
            [CBUUID UUIDWithString:kBSMetadataCharUUID],
            [CBUUID UUIDWithString:kBSDataCharUUID],
            [CBUUID UUIDWithString:kBSAckCharUUID],
            [CBUUID UUIDWithString:kBSControlCharUUID],
        ] forService:svc];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID.UUIDString isEqualToString:kBSMetadataCharUUID]) self.metadataChar = c;
        if ([c.UUID.UUIDString isEqualToString:kBSDataCharUUID])     self.dataChar     = c;
        if ([c.UUID.UUIDString isEqualToString:kBSAckCharUUID])      self.ackChar      = c;
        if ([c.UUID.UUIDString isEqualToString:kBSControlCharUUID])  self.controlChar  = c;
    }
    // Subscribe to ACK so we know when receiver is ready for next chunk
    if (self.ackChar)     [peripheral setNotifyValue:YES forCharacteristic:self.ackChar];
    if (self.controlChar) [peripheral setNotifyValue:YES forCharacteristic:self.controlChar];

    // Send metadata first
    if (self.metadataChar && self.sendMetadata) {
        NSData *jsonData = [self.sendMetadata toJSON];
        [peripheral writeValue:jsonData
             forCharacteristic:self.metadataChar
                          type:CBCharacteristicWriteWithResponse];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self sendDidFailWithError:error];
        });
        return;
    }
    // Metadata written — wait for ACCEPT on controlChar notify
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    NSString *uuid = characteristic.UUID.UUIDString;

    if ([uuid isEqualToString:kBSControlCharUUID]) {
        NSString *signal = [[NSString alloc] initWithData:characteristic.value
                                                 encoding:NSUTF8StringEncoding];
        if ([signal isEqualToString:@"ACCEPT"]) {
            // Receiver accepted — start sending chunks
            [self sendNextChunk];
        } else if ([signal isEqualToString:@"REJECT"]) {
            NSError *e = [NSError errorWithDomain:@"BSError" code:2
                                         userInfo:@{NSLocalizedDescriptionKey:@"Transfer rejected by receiver"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate transferManager:self sendDidFailWithError:e];
            });
        }
    } else if ([uuid isEqualToString:kBSAckCharUUID]) {
        // ACK received — send next chunk
        self.sendChunkIndex++;
        [self sendNextChunk];
    }
}

- (void)sendNextChunk {
    if (!self.fileData || !self.activePeer) return;

    NSUInteger offset = self.sendChunkIndex * kChunkSize;
    if (offset >= self.fileData.length) {
        // Transfer complete
        NSData *doneSignal = [@"DONE" dataUsingEncoding:NSUTF8StringEncoding];
        [self.activePeer writeValue:doneSignal
                  forCharacteristic:self.controlChar
                               type:CBCharacteristicWriteWithResponse];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self
                   didFinishSendingToPeer:self.activePeer];
        });
        return;
    }

    NSUInteger chunkLen = MIN(kChunkSize, self.fileData.length - offset);
    NSData *chunk = [self.fileData subdataWithRange:NSMakeRange(offset, chunkLen)];
    [self.activePeer writeValue:chunk
              forCharacteristic:self.dataChar
                           type:CBCharacteristicWriteWithResponse];

    float progress = (float)(offset + chunkLen) / (float)self.fileData.length;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate transferManager:self sendProgress:progress];
    });
}

// ── RECEIVER (CBPeripheralManager) ───────────────────────────────────────────

- (void)startAdvertising {
    if (self.peripheral.state != CBManagerStatePoweredOn) return;
    [self setupGATTService];
    NSString *deviceName = [[UIDevice currentDevice] name];
    [self.peripheral startAdvertising:@{
        CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithString:kBSServiceUUID]],
        CBAdvertisementDataLocalNameKey:     deviceName,
    }];
}

- (void)stopAdvertising {
    [self.peripheral stopAdvertising];
}

- (void)setupGATTService {
    self.rxMetadataChar = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kBSMetadataCharUUID]
          properties:CBCharacteristicPropertyWrite
               value:nil
         permissions:CBAttributePermissionsWriteable];

    self.rxDataChar = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kBSDataCharUUID]
          properties:CBCharacteristicPropertyWrite
               value:nil
         permissions:CBAttributePermissionsWriteable];

    self.rxAckChar = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kBSAckCharUUID]
          properties:CBCharacteristicPropertyNotify
               value:nil
         permissions:CBAttributePermissionsReadable];

    self.rxControlChar = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kBSControlCharUUID]
          properties:CBCharacteristicPropertyWrite | CBCharacteristicPropertyNotify
               value:nil
         permissions:CBAttributePermissionsWriteable | CBAttributePermissionsReadable];

    self.btService = [[CBMutableService alloc]
        initWithType:[CBUUID UUIDWithString:kBSServiceUUID]
             primary:YES];
    self.btService.characteristics = @[
        self.rxMetadataChar, self.rxDataChar, self.rxAckChar, self.rxControlChar
    ];
    [self.peripheral addService:self.btService];
}

// ── CBPeripheralManagerDelegate ───────────────────────────────────────────────

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    if (peripheral.state == CBManagerStatePoweredOn) {
        NSLog(@"[BlueShare] Peripheral BT powered on.");
    }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
            didAddService:(CBService *)service
                    error:(NSError *)error {
    if (error) NSLog(@"[BlueShare] Failed to add service: %@", error);
    else       NSLog(@"[BlueShare] GATT service registered.");
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
    for (CBATTRequest *request in requests) {
        NSString *uuid = request.characteristic.UUID.UUIDString;

        if ([uuid isEqualToString:kBSMetadataCharUUID]) {
            // Parse metadata and ask user to accept/reject
            self.recvMetadata = [BSTransferMetadata fromJSON:request.value];
            if (!self.recvMetadata) {
                [peripheral respondToRequest:request withResult:CBATTErrorInvalidAttributeValueLength];
                continue;
            }
            self.recvBuffer      = [NSMutableData new];
            self.recvChunkIndex  = 0;
            self.incomingSenderName = request.central.identifier.UUIDString; // best we can do w/o name

            [peripheral respondToRequest:request withResult:CBATTErrorSuccess];

            // Notify delegate (daemon will fire a local notification)
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.delegate transferManager:weakSelf
                    didReceiveIncomingRequestFrom:weakSelf.incomingSenderName
                                        metadata:weakSelf.recvMetadata
                                     acceptBlock:^(BOOL accept) {
                    NSString *signal = accept ? @"ACCEPT" : @"REJECT";
                    NSData   *sig    = [signal dataUsingEncoding:NSUTF8StringEncoding];
                    [weakSelf.peripheral updateValue:sig
                                  forCharacteristic:weakSelf.rxControlChar
                               onSubscribedCentrals:nil];
                }];
            });

        } else if ([uuid isEqualToString:kBSDataCharUUID]) {
            // Accumulate chunk
            [self.recvBuffer appendData:request.value];
            self.recvChunkIndex++;
            [peripheral respondToRequest:request withResult:CBATTErrorSuccess];

            float progress = (float)self.recvBuffer.length / (float)self.recvMetadata.totalBytes;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate transferManager:self receiveProgress:progress];
            });

            // Send ACK
            NSData *ack = [@"ACK" dataUsingEncoding:NSUTF8StringEncoding];
            [peripheral updateValue:ack
                  forCharacteristic:self.rxAckChar
               onSubscribedCentrals:nil];

        } else if ([uuid isEqualToString:kBSControlCharUUID]) {
            NSString *signal = [[NSString alloc] initWithData:request.value
                                                     encoding:NSUTF8StringEncoding];
            [peripheral respondToRequest:request withResult:CBATTErrorSuccess];

            if ([signal isEqualToString:@"DONE"]) {
                [self finaliseReceivedFile];
            }
        }
    }
}

- (void)finaliseReceivedFile {
    // Save to /var/mobile/Documents/BlueShare/<fileName>
    NSString *dir  = @"/var/mobile/Documents/BlueShare";
    NSString *path = [dir stringByAppendingPathComponent:self.recvMetadata.fileName];

    // Avoid overwriting — append index if needed
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger idx = 1;
    NSString *finalPath = path;
    while ([fm fileExistsAtPath:finalPath]) {
        NSString *ext  = path.pathExtension;
        NSString *base = [path.lastPathComponent stringByDeletingPathExtension];
        finalPath = [dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@_%lu.%@", base, (unsigned long)idx++, ext]];
    }

    BOOL ok = [self.recvBuffer writeToFile:finalPath atomically:YES];
    if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate transferManager:self didReceiveFileAtPath:finalPath];
        });
    }

    self.recvBuffer     = nil;
    self.recvMetadata   = nil;
    self.recvChunkIndex = 0;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (NSString *)mimeTypeForURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    NSDictionary *map = @{
        @"jpg":  @"image/jpeg",
        @"jpeg": @"image/jpeg",
        @"png":  @"image/png",
        @"gif":  @"image/gif",
        @"pdf":  @"application/pdf",
        @"mp4":  @"video/mp4",
        @"mp3":  @"audio/mpeg",
        @"zip":  @"application/zip",
        @"txt":  @"text/plain",
        @"mov":  @"video/quicktime",
    };
    return map[ext] ?: @"application/octet-stream";
}

@end

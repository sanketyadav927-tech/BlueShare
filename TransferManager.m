// TransferManager.m
// Full CoreBluetooth implementation for BlueShare peer-to-peer file transfer.

#import "TransferManager.h"
#import <UserNotifications/UserNotifications.h>

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
        // Queues
        dispatch_queue_t cq = dispatch_queue_create("com.blueshare.central",  DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t pq = dispatch_queue_create("com.blueshare.peripheral",DISPATCH_QUEUE_SERIAL);
        _central    = [[CBCentralManager    alloc] initWithDelegate:self queue:cq];
        _peripheral = [[CBPeripheralManager alloc] initWithDelegate:self queue:pq];
    }
    return self;
}

// ── SENDER ────────────────────────────────────────────────────────────────────

- (void)startScanningForPeers {
    if (self.central.state != CBManagerStatePoweredOn) return;
    [self.discoveredPeers removeAllObjects];
    CBUUID *svcUUID = [CBUUID UUIDWithString:kBSServiceUUID];
    [self.central scanForPeripheralsWithServices:@[svcUUID]
                                         options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (void)stopScanning {
    [self.central stopScan];
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
    if (central.state == CBManagerStatePoweredOn) {
        NSLog(@"[BlueShare] Central BT powered on.");
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

// TransferManager.h
// Central singleton that manages all CoreBluetooth state for BlueShare.
// Acts as both a CBCentralManager (sender) and CBPeripheralManager (receiver).

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

// ── Service & Characteristic UUIDs ──────────────────────────────────────────
// All peers advertise this service so they can discover each other.
extern NSString *const kBSServiceUUID;            // "BA5E5001-…"
extern NSString *const kBSMetadataCharUUID;       // Sender writes JSON metadata first
extern NSString *const kBSDataCharUUID;           // Sender writes 512-byte chunks here
extern NSString *const kBSAckCharUUID;            // Receiver notifies ACK after each chunk
extern NSString *const kBSControlCharUUID;        // "ACCEPT" / "REJECT" / "DONE" signals

// ── Transfer metadata (sent as JSON over kBSMetadataCharUUID) ───────────────
@interface BSTransferMetadata : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *fileName;   // e.g. "photo.jpg"
@property (nonatomic, copy) NSString *mimeType;   // e.g. "image/jpeg"
@property (nonatomic) NSUInteger     totalBytes;
@property (nonatomic) NSUInteger     chunkCount;
+ (nullable instancetype)fromJSON:(NSData *)json;
- (NSData *)toJSON;
@end

// ── Callbacks ────────────────────────────────────────────────────────────────
@protocol BSTransferManagerDelegate <NSObject>
@optional
// Sender side
- (void)transferManager:(id)mgr didUpdateBluetoothState:(CBManagerState)state;
- (void)transferManager:(id)mgr didDiscoverPeer:(CBPeripheral *)peer name:(NSString *)name;
- (void)transferManager:(id)mgr didConnectToPeer:(CBPeripheral *)peer;
- (void)transferManager:(id)mgr sendProgress:(float)progress;          // 0.0 – 1.0
- (void)transferManager:(id)mgr didFinishSendingToPeer:(CBPeripheral *)peer;
- (void)transferManager:(id)mgr sendDidFailWithError:(NSError *)error;

// Receiver side (daemon & in-app)
- (void)transferManager:(id)mgr didReceiveIncomingRequestFrom:(NSString *)senderName
               metadata:(BSTransferMetadata *)meta
              acceptBlock:(void (^)(BOOL accept))acceptBlock;
- (void)transferManager:(id)mgr receiveProgress:(float)progress;
- (void)transferManager:(id)mgr didReceiveFileAtPath:(NSString *)path;
@end

// ── Main Manager ─────────────────────────────────────────────────────────────
@interface BSTransferManager : NSObject <CBCentralManagerDelegate,
                                          CBPeripheralDelegate,
                                          CBPeripheralManagerDelegate>

@property (nonatomic, weak, nullable) id<BSTransferManagerDelegate> delegate;

+ (instancetype)sharedManager;

/// Start scanning for nearby BlueShare peers (sender role).
- (void)startScanningForPeers;
- (void)stopScanning;

/// Send a file to a discovered peer.
- (void)sendFileAtURL:(NSURL *)fileURL toPeer:(CBPeripheral *)peer;

/// Start advertising as a receiver (called by daemon).
- (void)startAdvertising;
- (void)stopAdvertising;

@end

NS_ASSUME_NONNULL_END

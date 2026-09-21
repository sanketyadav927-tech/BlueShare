// BTShareDaemon/DaemonTransferServer.h
// Receiver-side server that runs in the background daemon process.
// Advertises as a BlueShare peer, handles incoming file transfers,
// fires local notifications, and saves files to Documents/BlueShare/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DaemonTransferServer : NSObject
+ (instancetype)sharedServer;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END

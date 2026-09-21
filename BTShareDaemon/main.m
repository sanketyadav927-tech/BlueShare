// BTShareDaemon/main.m
// Entry point for the BTShareDaemon LaunchDaemon.
// Keeps the process alive with a CFRunLoop so CoreBluetooth can operate.

#import <Foundation/Foundation.h>
#import "DaemonTransferServer.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[BTShareDaemon] Starting up…");

        // Ensure the Documents/BlueShare directory exists
        NSString *dir = @"/var/mobile/Documents/BlueShare";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
            NSLog(@"[BTShareDaemon] Created BlueShare directory.");
        }

        // Start the transfer server
        [[DaemonTransferServer sharedServer] start];

        NSLog(@"[BTShareDaemon] Running. Waiting for Bluetooth connections…");

        // Run the loop forever (launchd will restart us if we crash)
        CFRunLoopRun();
    }
    return 0;
}

// Prefs/BSPrefsListController.m
// Preferences pane for Settings → BlueShare
// Author: Sanket Yadav

#import "BSPrefsListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>

@implementation BSPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        } @catch (NSException *e) {
            NSLog(@"[BlueSharePrefs] Error loading Root.plist specifiers: %@", e);
        }

        if (!_specifiers || _specifiers.count == 0) {
            // Safety fallback: load directly from plist path if bundle lookup failed
            NSString *path = nil;
            NSBundle *bundle = [NSBundle bundleForClass:[self class]];
            path = [bundle pathForResource:@"Root" ofType:@"plist"];
            if (!path) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/Library/PreferenceBundles/BlueSharePrefs.bundle/Root.plist"]) {
                    path = @"/var/jb/Library/PreferenceBundles/BlueSharePrefs.bundle/Root.plist";
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Library/PreferenceBundles/BlueSharePrefs.bundle/Root.plist"]) {
                    path = @"/Library/PreferenceBundles/BlueSharePrefs.bundle/Root.plist";
                }
            }
            if (path) {
                @try {
                    _specifiers = [self loadSpecifiersFromPlistName:path target:self];
                } @catch (NSException *e) {
                    NSLog(@"[BlueSharePrefs] Error loading from path: %@", e);
                }
            }
        }

        if (!_specifiers) {
            _specifiers = [NSArray array];
        }
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *path = @"/var/mobile/Library/Preferences/com.yourrepo.blueshare.plist";
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:path];
    return (settings[specifier.properties[@"key"]]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *path = @"/var/mobile/Library/Preferences/com.yourrepo.blueshare.plist";
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    [settings setObject:value forKey:specifier.properties[@"key"]];
    [settings writeToFile:path atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR("com.yourrepo.blueshare/settingschanged"),
                                        NULL, NULL, YES);
}

- (id)authorValue {
    return @"Sanket Yadav";
}

- (id)versionValue {
    return @"1.0.0";
}

- (id)packageValue {
    return @"com.yourrepo.blueshare";
}

- (id)savePathValue {
    return @"/var/mobile/Documents/BlueShare";
}

- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Respring"
                         message:@"This will restart SpringBoard to apply changes. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) {
        pid_t pid;
        const char *argv[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

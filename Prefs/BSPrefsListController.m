// Prefs/BSPrefsListController.m
// Preferences pane that appears in Settings → BlueShare.
// Author: Sanket Yadav

#import "BSPrefsListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>

// ── Custom Banner Header View ─────────────────────────────────────────────────
@interface BSBannerView : UIView
@end

@implementation BSBannerView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Gradient background
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 90);
        grad.colors = @[
            (__bridge id)[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.2 green:0.2 blue:0.9 alpha:1.0].CGColor,
        ];
        grad.startPoint = CGPointMake(0, 0);
        grad.endPoint   = CGPointMake(1, 1);
        [self.layer addSublayer:grad];

        // BT icon
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:36 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
                               withConfiguration:cfg];
        UIImageView *iv = [[UIImageView alloc] initWithImage:
            [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        iv.tintColor = [UIColor whiteColor];
        iv.frame = CGRectMake(20, 25, 40, 40);
        iv.contentMode = UIViewContentModeScaleAspectFit;

        // Tweak name label
        UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(74, 18, 250, 32)];
        nameLabel.text = @"BlueShare";
        nameLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        nameLabel.textColor = [UIColor whiteColor];

        // Author label
        UILabel *authorLabel = [[UILabel alloc] initWithFrame:CGRectMake(74, 50, 250, 20)];
        authorLabel.text = @"by Sanket Yadav";
        authorLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        authorLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];

        [self addSubview:iv];
        [self addSubview:nameLabel];
        [self addSubview:authorLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *l in self.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) {
            l.frame = self.bounds;
        }
    }
}

@end

// ── BSPrefsListController ─────────────────────────────────────────────────────
@implementation BSPrefsListController

- (void)viewDidLoad {
    [super viewDidLoad];

    CGFloat width = self.table.bounds.size.width;
    if (width <= 0) {
        width = [UIScreen mainScreen].bounds.size.width;
    }
    BSBannerView *banner = [[BSBannerView alloc] initWithFrame:CGRectMake(0, 0, width, 90)];
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.table.tableHeaderView = banner;
}

// ── Preferences Read/Write Helpers ────────────────────────────────────────────
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

// ── Value Getters for PSTitleValueCell ─────────────────────────────────────────
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

// ── Respring action ───────────────────────────────────────────────────────────
- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Respring"
                         message:@"This will respring your device. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) {
        // Standard respring — restarts SpringBoard cleanly across rootful and rootless
        pid_t pid;
        const char *argv[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── Specifiers ────────────────────────────────────────────────────────────────
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray new];

        // ── Section 0: Enable toggle ─────────────────────────────────────────
        PSSpecifier *enableHeader = [PSSpecifier
            preferenceSpecifierNamed:@"General"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [enableHeader setProperty:@"Share any file with nearby iPhones over Bluetooth."
                          forKey:@"footerText"];
        [specs addObject:enableHeader];

        PSSpecifier *enabled = [PSSpecifier
            preferenceSpecifierNamed:@"Enable BlueShare"
            target:self
               set:@selector(setPreferenceValue:specifier:)
               get:@selector(readPreferenceValue:)
            detail:nil
              cell:PSSwitchCell
              edit:nil];
        [enabled setProperty:@"BSEnabled" forKey:@"key"];
        [enabled setProperty:@"com.yourrepo.blueshare" forKey:@"defaults"];
        [enabled setProperty:@(YES) forKey:@"default"];
        [specs addObject:enabled];

        // ── Section 1: Save location ─────────────────────────────────────────
        PSSpecifier *locHeader = [PSSpecifier
            preferenceSpecifierNamed:@"Save Location"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [locHeader setProperty:@"Received files are saved here." forKey:@"footerText"];
        [specs addObject:locHeader];

        PSSpecifier *savePath = [PSSpecifier
            preferenceSpecifierNamed:@"Files Folder"
            target:self set:nil get:@selector(savePathValue) detail:nil
              cell:PSTitleValueCell edit:nil];
        [specs addObject:savePath];

        // ── Section 2: Respring ──────────────────────────────────────────────
        PSSpecifier *respringHeader = [PSSpecifier
            preferenceSpecifierNamed:@"SpringBoard"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [respringHeader setProperty:@"Respring to apply changes after toggling."
                             forKey:@"footerText"];
        [specs addObject:respringHeader];

        PSSpecifier *respringBtn = [PSSpecifier
            preferenceSpecifierNamed:@"Respring Device"
            target:self
               set:nil
               get:nil
            detail:nil
              cell:PSButtonCell
              edit:nil];
        [respringBtn setProperty:NSStringFromSelector(@selector(respring)) forKey:@"action"];
        [specs addObject:respringBtn];

        // ── Section 3: About ─────────────────────────────────────────────────
        PSSpecifier *aboutHeader = [PSSpecifier
            preferenceSpecifierNamed:@"About"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [specs addObject:aboutHeader];

        PSSpecifier *author = [PSSpecifier
            preferenceSpecifierNamed:@"Developer"
            target:self set:nil get:@selector(authorValue) detail:nil
              cell:PSTitleValueCell edit:nil];
        [specs addObject:author];

        PSSpecifier *version = [PSSpecifier
            preferenceSpecifierNamed:@"Version"
            target:self set:nil get:@selector(versionValue) detail:nil
              cell:PSTitleValueCell edit:nil];
        [specs addObject:version];

        PSSpecifier *package = [PSSpecifier
            preferenceSpecifierNamed:@"Package"
            target:self set:nil get:@selector(packageValue) detail:nil
              cell:PSTitleValueCell edit:nil];
        [specs addObject:package];

        _specifiers = specs;
    }
    return _specifiers;
}

@end

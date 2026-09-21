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
        grad.frame = self.bounds;
        grad.colors = @[
            (__bridge id)[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.2 green:0.2 blue:0.9 alpha:1.0].CGColor,
        ];
        grad.startPoint = CGPointMake(0, 0);
        grad.endPoint   = CGPointMake(1, 1);
        [self.layer addSublayer:grad];

        // BT icon
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:40 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
                               withConfiguration:cfg];
        UIImageView *iv = [[UIImageView alloc] initWithImage:
            [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        iv.tintColor = [UIColor whiteColor];
        iv.translatesAutoresizingMaskIntoConstraints = NO;

        // Tweak name label
        UILabel *nameLabel = [UILabel new];
        nameLabel.text = @"BlueShare";
        nameLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
        nameLabel.textColor = [UIColor whiteColor];
        nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Author label
        UILabel *authorLabel = [UILabel new];
        authorLabel.text = @"by Sanket Yadav";
        authorLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        authorLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        authorLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:iv];
        [self addSubview:nameLabel];
        [self addSubview:authorLabel];

        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor  constant:24],
            [iv.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [nameLabel.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:14],
            [nameLabel.topAnchor    constraintEqualToAnchor:self.topAnchor    constant:22],

            [authorLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
            [authorLabel.topAnchor    constraintEqualToAnchor:nameLabel.bottomAnchor constant:4],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Keep gradient in sync with frame
    for (CALayer *l in self.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) l.frame = self.bounds;
    }
}
@end

@implementation BSPrefsListController

// ── Custom banner at top of pane ──────────────────────────────────────────────
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 0) return nil;
    BSBannerView *banner = [[BSBannerView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 90)];
    return banner;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 90 : UITableViewAutomaticDimension;
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
        // Standard respring — restarts SpringBoard cleanly
        pid_t pid;
        const char *argv[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray *)specifiers {
    if (!_specifiers) {

        // ── Section 0: Enable toggle ─────────────────────────────────────────
        PSSpecifier *enableHeader = [PSSpecifier
            preferenceSpecifierNamed:@"General"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [enableHeader setProperty:@"Share any file with nearby iPhones over Bluetooth."
                          forKey:@"footerText"];

        PSSpecifier *enabled = [PSSpecifier
            preferenceSpecifierNamed:@"Enable BlueShare"
            target:self
               set:@selector(setPreferenceValue:specifier:)
               get:@selector(readPreferenceValue:)
            detail:nil
              cell:PSSwitchCell
              edit:nil];
        [enabled setProperty:@"BSEnabled"            forKey:@"key"];
        [enabled setProperty:@"com.yourrepo.blueshare" forKey:@"defaults"];
        [enabled setProperty:@(YES)                   forKey:@"default"];

        // ── Section 1: Save location ─────────────────────────────────────────
        PSSpecifier *locHeader = [PSSpecifier
            preferenceSpecifierNamed:@"Save Location"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [locHeader setProperty:@"Received files are saved here." forKey:@"footerText"];

        PSSpecifier *savePath = [PSSpecifier
            preferenceSpecifierNamed:@"Files Folder"
            target:self set:nil get:nil detail:nil
              cell:PSStaticTextCell edit:nil];
        [savePath setProperty:@"/var/mobile/Documents/BlueShare"
                       forKey:@"staticTextValue"];

        // ── Section 2: Respring ──────────────────────────────────────────────
        PSSpecifier *respringHeader = [PSSpecifier
            preferenceSpecifierNamed:@"SpringBoard"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [respringHeader setProperty:@"Respring to apply changes after toggling."
                             forKey:@"footerText"];

        PSSpecifier *respringBtn = [PSSpecifier
            preferenceSpecifierNamed:@"Respring Device"
            target:self
               set:nil
               get:nil
            detail:nil
              cell:PSButtonCell
              edit:nil];
        [respringBtn setButtonAction:@selector(respring)];

        // ── Section 3: About ─────────────────────────────────────────────────
        PSSpecifier *aboutHeader = [PSSpecifier
            preferenceSpecifierNamed:@"About"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];

        PSSpecifier *author = [PSSpecifier
            preferenceSpecifierNamed:@"Developer"
            target:self set:nil get:nil detail:nil
              cell:PSStaticTextCell edit:nil];
        [author setProperty:@"Sanket Yadav" forKey:@"staticTextValue"];

        PSSpecifier *version = [PSSpecifier
            preferenceSpecifierNamed:@"Version"
            target:self set:nil get:nil detail:nil
              cell:PSStaticTextCell edit:nil];
        [version setProperty:@"1.0.0" forKey:@"staticTextValue"];

        PSSpecifier *package = [PSSpecifier
            preferenceSpecifierNamed:@"Package"
            target:self set:nil get:nil detail:nil
              cell:PSStaticTextCell edit:nil];
        [package setProperty:@"com.yourrepo.blueshare" forKey:@"staticTextValue"];

        _specifiers = [@[
            enableHeader,  enabled,
            locHeader,     savePath,
            respringHeader, respringBtn,
            aboutHeader,   author, version, package,
        ] mutableCopy];
    }
    return _specifiers;
}

@end

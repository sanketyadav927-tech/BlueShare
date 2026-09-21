// Prefs/BSPrefsListController.m
// Preferences pane that appears in Settings → BlueShare.

#import "BSPrefsListController.h"
#import <Preferences/PSSpecifier.h>

@implementation BSPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        // ── Header ──────────────────────────────────────────────────────────
        PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:@"BlueShare"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [header setProperty:@"Share files with nearby iPhones over Bluetooth."
                     forKey:@"footerText"];

        // ── Master toggle ────────────────────────────────────────────────────
        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"Enable BlueShare"
            target:self
               set:@selector(setPreferenceValue:specifier:)
               get:@selector(readPreferenceValue:)
            detail:nil
              cell:PSSwitchCell
              edit:nil];
        [enabled setProperty:@"BSEnabled"                          forKey:@"key"];
        [enabled setProperty:@"com.yourrepo.blueshare"             forKey:@"defaults"];
        [enabled setProperty:@(YES)                                forKey:@"default"];

        // ── Save location section ────────────────────────────────────────────
        PSSpecifier *locHeader = [PSSpecifier preferenceSpecifierNamed:@"Save Location"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [locHeader setProperty:@"Received files are saved here." forKey:@"footerText"];

        PSSpecifier *savePath = [PSSpecifier preferenceSpecifierNamed:@"Files Folder"
            target:self
               set:nil get:nil
            detail:nil
              cell:PSStaticTextCell
              edit:nil];
        [savePath setProperty:@"/var/mobile/Documents/BlueShare" forKey:@"staticTextValue"];

        // ── About section ────────────────────────────────────────────────────
        PSSpecifier *aboutHeader = [PSSpecifier preferenceSpecifierNamed:@"About"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];

        PSSpecifier *version = [PSSpecifier preferenceSpecifierNamed:@"Version"
            target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
        [version setProperty:@"1.0.0" forKey:@"staticTextValue"];

        _specifiers = @[header, enabled, locHeader, savePath, aboutHeader, version];
    }
    return _specifiers;
}

@end

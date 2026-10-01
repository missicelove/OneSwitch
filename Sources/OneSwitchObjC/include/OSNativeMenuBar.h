// OSNativeMenuBar.h — exception-safe bridge to macOS 27's menu-bar visibility restriction.
//
// macOS 27 lets a process restrict the menu bar to an allow-list of system items and apps (the mechanism
// behind assessment / exam mode, private framework MenuBarClientCore). macOS then hides every other status
// item and reflows the bar itself — no overflow chevron, no gap. The restriction lasts until it is
// invalidated or the holding process exits (macOS restores the bar by itself).
// Approach learned from Hidden Bar (MIT, github.com/dwarvesf/hidden, NativeVisibilityEngine).
//
// Objective-C so that exceptions raised by a changed private API are caught instead of crashing.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the framework, both classes and every selector used resolve on this macOS.
BOOL OSNativeMenuBarIsAvailable(void);

/// Keeps only the given system items (numeric identifiers) and apps (bundle identifiers) visible.
/// The completion runs on the main queue with the assertion to hold, or an error.
void OSNativeMenuBarActivate(NSArray<NSNumber *> *allowedSystemItems,
                             NSArray<NSString *> *allowedBundleIdentifiers,
                             void (^completion)(id _Nullable assertion, NSError * _Nullable error));

/// Drops a restriction obtained from OSNativeMenuBarActivate (safe to call more than once).
void OSNativeMenuBarInvalidate(id assertion);

NS_ASSUME_NONNULL_END

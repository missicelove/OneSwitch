#import "OSNativeMenuBar.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const kFrameworkPath = @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const kConfigurationClass = @"MBAssessmentModeConfiguration";
static NSString *const kAssertionClass = @"MBAssessmentModeAssertion";

static NSError *OSNativeMenuBarError(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:@"OSNativeMenuBar" code:code userInfo:@{NSLocalizedDescriptionKey: reason}];
}

BOOL OSNativeMenuBarIsAvailable(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen(kFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) { return; }
        Class configuration = NSClassFromString(kConfigurationClass);
        Class assertion = NSClassFromString(kAssertionClass);
        available = configuration && assertion
            && [configuration instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
            && [assertion instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
            && [assertion instancesRespondToSelector:@selector(invalidate)];
    });
    return available;
}

void OSNativeMenuBarActivate(NSArray<NSNumber *> *allowedSystemItems,
                             NSArray<NSString *> *allowedBundleIdentifiers,
                             void (^completion)(id _Nullable assertion, NSError * _Nullable error)) {
    void (^finish)(id, NSError *) = ^(id assertion, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(assertion, error); });
    };
    if (!OSNativeMenuBarIsAvailable()) {
        finish(nil, OSNativeMenuBarError(1, @"MenuBarClientCore is unavailable on this macOS"));
        return;
    }
    @try {
        // Both lists must be NSArrays (the framework indexes into them).
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(kConfigurationClass) alloc], @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:),
            [allowedSystemItems copy], [allowedBundleIdentifiers copy]);
        id assertion = [[NSClassFromString(kAssertionClass) alloc] init];
        if (!configuration || !assertion) {
            finish(nil, OSNativeMenuBarError(2, @"Could not create the visibility configuration"));
            return;
        }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, @selector(activateWithConfiguration:completionHandler:), configuration, ^(NSError *error) {
                finish(error ? nil : assertion, error);
            });
    } @catch (NSException *exception) {
        finish(nil, OSNativeMenuBarError(3, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]));
    }
}

void OSNativeMenuBarInvalidate(id assertion) {
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) {
        NSLog(@"OSNativeMenuBar: invalidate raised %@: %@", exception.name, exception.reason);
    }
}

// The code the shell downloads, signs on the phone and loads. Built as an
// unsigned arm64 dylib by the GitHub workflow; PAYLOAD_VERSION is the release tag.
#import <UIKit/UIKit.h>
#include <stdio.h>

#ifndef PAYLOAD_VERSION
#define PAYLOAD_VERSION "dev"
#endif

#define EXPORT __attribute__((visibility("default")))

EXPORT const char *sidestep_payload_hello(void) {
    static char buf[256];
    snprintf(buf, sizeof buf, "payload %s, native code running on iOS %s",
             PAYLOAD_VERSION, UIDevice.currentDevice.systemVersion.UTF8String);
    return buf;
}

/// Returns a retained UIViewController (the shell takes ownership).
EXPORT void *sidestep_payload_make_view_controller(void) {
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemTealColor;

    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.text = [NSString stringWithFormat:
        @"This screen was drawn by native code downloaded from GitHub and signed on this phone.\n\nPayload %s",
        PAYLOAD_VERSION];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-32],
    ]];
    return (__bridge_retained void *)vc;
}

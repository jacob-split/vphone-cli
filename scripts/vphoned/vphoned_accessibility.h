/*
 * vphoned_accessibility — Semantic accessibility bridge.
 *
 * Proxies length-prefixed JSON to VPhoneAX inside SpringBoard and performs
 * resolved semantic taps through vphoned's existing HID injector.
 */
#pragma once
#import <Foundation/Foundation.h>

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg);

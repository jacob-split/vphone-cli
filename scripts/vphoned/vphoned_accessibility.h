/*
 * vphoned_accessibility — Semantic accessibility bridge.
 *
 * Proxies length-prefixed JSON to VPhoneAX inside SpringBoard and performs
 * resolved semantic taps through vphoned's existing HID injector.
 */
#pragma once
#import <Foundation/Foundation.h>

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg);

/// Best-effort foreground app context from the SpringBoard semantic broker.
/// Returns nil when the broker is unavailable (non-JB guests use app fallbacks).
NSDictionary *vp_accessibility_frontmost_context(void);

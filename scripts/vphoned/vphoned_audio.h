#pragma once
#import <Foundation/Foundation.h>

/// Return structured AVAudioSession route/capability information without
/// activating or changing the session. This is intentionally passive so it
/// never competes with the app under test for microphone/speaker ownership.
NSDictionary *vp_handle_audio_command(NSDictionary *msg);

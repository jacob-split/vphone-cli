#import "vphoned_audio.h"
#import "vphoned_protocol.h"
#import <AVFAudio/AVFAudio.h>

static NSDictionary *vp_audio_port(AVAudioSessionPortDescription *port) {
  if (!port) return @{};
  NSMutableDictionary *r = [NSMutableDictionary dictionary];
  if (port.portName) r[@"name"] = port.portName;
  if (port.portType) r[@"type"] = port.portType;
  if (port.UID) r[@"uid"] = port.UID;
  r[@"channels"] = @(port.channels.count);
  if (@available(iOS 14.0, *)) {
    if (port.spatialAudioEnabled) r[@"spatial_audio"] = @YES;
  }
  return r;
}

NSDictionary *vp_handle_audio_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *type = [msg[@"t"] isKindOfClass:[NSString class]] ? msg[@"t"] : @"";
  BOOL probe = [type isEqualToString:@"audio_probe"];
  if (![type isEqualToString:@"audio_status"] && !probe) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown audio command: %@", type];
    return r;
  }

  AVAudioSession *session = AVAudioSession.sharedInstance;
  NSString *oldCategory = session.category;
  NSString *oldMode = session.mode;
  AVAudioSessionCategoryOptions oldOptions = session.categoryOptions;
  NSError *probeError = nil;
  BOOL categoryOK = YES, activeOK = YES;
  if (probe) {
    categoryOK = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                                  mode:AVAudioSessionModeDefault
                               options:AVAudioSessionCategoryOptionDefaultToSpeaker
                                 error:&probeError];
    if (categoryOK) activeOK = [session setActive:YES error:&probeError];
    if (activeOK) usleep(250000);
  }
  NSMutableArray *inputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription *p in session.currentRoute.inputs) {
    [inputs addObject:vp_audio_port(p)];
  }
  NSMutableArray *outputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription *p in session.currentRoute.outputs) {
    [outputs addObject:vp_audio_port(p)];
  }
  NSMutableArray *available = [NSMutableArray array];
  for (AVAudioSessionPortDescription *p in session.availableInputs ?: @[]) {
    [available addObject:vp_audio_port(p)];
  }

  NSMutableDictionary *r = vp_make_response(@"audio", reqId);
  r[@"inputs"] = inputs;
  r[@"outputs"] = outputs;
  r[@"available_inputs"] = available;
  r[@"input_available"] = @(session.inputAvailable);
  r[@"sample_rate"] = @(session.sampleRate);
  r[@"io_buffer_duration"] = @(session.IOBufferDuration);
  r[@"output_volume"] = @(session.outputVolume);
  r[@"input_channels"] = @(session.inputNumberOfChannels);
  r[@"output_channels"] = @(session.outputNumberOfChannels);
  r[@"max_input_channels"] = @(session.maximumInputNumberOfChannels);
  r[@"max_output_channels"] = @(session.maximumOutputNumberOfChannels);
  r[@"category"] = session.category ?: @"";
  r[@"mode"] = session.mode ?: @"";
  if (session.preferredInput) r[@"preferred_input"] = vp_audio_port(session.preferredInput);
  if (probe) {
    r[@"probe_category_ok"] = @(categoryOK);
    r[@"probe_active_ok"] = @(activeOK);
    if (probeError) r[@"probe_error"] = probeError.localizedDescription ?: @"unknown";
    NSError *deactivateError = nil;
    BOOL deactivated = [session setActive:NO
                                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                      error:&deactivateError];
    NSError *restoreError = nil;
    BOOL restored = [session setCategory:oldCategory ?: AVAudioSessionCategorySoloAmbient
                                    mode:oldMode ?: AVAudioSessionModeDefault
                                 options:oldOptions error:&restoreError];
    r[@"probe_deactivated"] = @(deactivated);
    r[@"probe_restored"] = @(restored);
    if (deactivateError) r[@"deactivate_error"] = deactivateError.localizedDescription ?: @"unknown";
    if (restoreError) r[@"restore_error"] = restoreError.localizedDescription ?: @"unknown";
  }
  return r;
}

 /*
 ==============================================================================
 
 This file is part of the iPlug 2 library. Copyright (C) the iPlug 2 developers. 
 
 See LICENSE.txt for  more info.
 
 ==============================================================================
*/

#import "IPlugAUPlayer.h"
#import <CoreAudio/AudioHardwareBase.h>
#include "IPlugConstants.h"

// The iOS SDK ships CoreAudio's object types (AudioObjectID, AudioObjectPropertyAddress,
// kAudioObjectPropertyScopeGlobal...) but not <CoreAudio/AudioHardware.h>, so the
// system-object ID, the two hardware property selectors and the block-based listener API
// used below are missing. Declare just what this file needs; the symbols live in
// AudioToolbox and link fine, and Apple documents this content as iOS-available.
extern "C" {
enum {
  kIPlugAudioObjectSystemObject = 1,                     // == kAudioObjectSystemObject
  kIPlugHardwarePropDevices = 'dev#',                    // == kAudioHardwarePropertyDevices
  kIPlugHardwarePropDefaultInputDevice = 'dIn ',         // == kAudioHardwarePropertyDefaultInputDevice
};
// Same shape as AudioObjectPropertyListenerBlock in <CoreAudio/AudioHardware.h>
// (typedef distinct name to avoid clashing with any SDK declaration that leaks in transitively).
typedef void (^IPlugPropertyListenerBlock)(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses);
extern OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                                    dispatch_queue_t inDispatchQueue, IPlugPropertyListenerBlock inListenerBlock);
}
#include "config.h"

#if !__has_feature(objc_arc)
#error This file must be compiled with Arc. Use -fobjc-arc flag
#endif

@implementation IPlugAUPlayer
{
  AVAudioEngine* audioEngine;
  AVAudioUnit* avAudioUnit;
  UInt32 componentType;
#if PLUG_TYPE != 1
  BOOL inputConnected;
  BOOL relinkScheduled;
#endif
}

// Wire the plugin's output side using the CURRENT hardware output format.
// The upstream wiring pins the plugin's own bus format (iplug::DEFAULT_SAMPLE_RATE,
// 48 kHz by default); when a USB audio interface runs the session at its native rate
// (IK TONEX ONE: 44.1 kHz x 2), that stale 48 kHz connection makes the whole render
// graph stall - the input node emits nothing and the output is silent. Match hardware.
- (void) connectAudioUnitOutput
{
  // The node's OUTPUT side is the hardware format. Its input side is only whatever the engine
  // wired by default (44.1 kHz from -mainMixerNode before the session is active), which
  // dragged the plugin to 44.1 kHz on 48 kHz hardware.
  AVAudioFormat* outputHWFormat = [audioEngine.outputNode outputFormatForBus:0];
  if (outputHWFormat == nil || outputHWFormat.sampleRate <= 0.0 || outputHWFormat.channelCount == 0)
    outputHWFormat = [avAudioUnit outputFormatForBus:0]; // simulator / no settled route: plugin format

  auto numOutputBuses = [avAudioUnit numberOfOutputs];
  AVAudioMixerNode* mainMixer = [audioEngine mainMixerNode];

  // Route AU -> mainMixer -> outputNode in both cases: the mixer is the node the
  // engine already owns, so one wiring shape covers single- and multi-bus plugins.
  if (numOutputBuses > 1)
  {
    // Assume all output buses are the same format
    for (int busIdx = 0; busIdx < numOutputBuses; busIdx++)
      [audioEngine connect:avAudioUnit to:mainMixer fromBus:busIdx toBus:[mainMixer nextAvailableInputBus] format:outputHWFormat];
  }
  else
  {
    [audioEngine connect:avAudioUnit to:mainMixer format:outputHWFormat];
  }
  [audioEngine connect:mainMixer to:audioEngine.outputNode format:outputHWFormat];
}

#if PLUG_TYPE != 1
// Wire (or re-wire) the hardware input to the plugin's input bus in the input node's
// CURRENT hardware format. External USB interfaces (e.g. IK TONEX ONE) report a
// different format than the built-in mic, and plugging one in while running changes
// it; -scheduleRelinkInput: re-runs this from the config/route observers so the
// connection follows the active route instead of staying on the format captured at launch.
- (void) linkInputIfPossible
{
  AVAudioFormat* micInputFormat = [[audioEngine inputNode] inputFormatForBus:0];

  // The iOS Simulator can report an invalid input node hardware format (sample rate 0),
  // which makes -[AVAudioEngine connect:to:format:] throw ("IsFormatSampleRateAndChannelCountValid(format)"
  // / "Input HW format is invalid"). Skip the mic connection in that case; the plugin's
  // input bus is then fed silence. A real device reports a valid format once the session
  // is active, and a route change retries.
  if (micInputFormat == nil || micInputFormat.sampleRate <= 0.0 || micInputFormat.channelCount == 0)
  {
    NSLog(@"Input HW format invalid - running without audio input (will retry on route change)");
    if (inputConnected)
    {
      [audioEngine disconnectNodeInput:avAudioUnit bus:0];
      inputConnected = NO;
    }
    [self connectAudioUnitOutput];
    return;
  }

  if (inputConnected)
    [audioEngine disconnectNodeInput:avAudioUnit bus:0];
  [audioEngine connect:audioEngine.inputNode to:avAudioUnit format:micInputFormat];
  inputConnected = YES;
  NSLog(@"Plugin input bus wired to %g Hz x %u ch", micInputFormat.sampleRate, (unsigned) micInputFormat.channelCount);

  [self connectAudioUnitOutput];
}

// Coalesced re-link on route changes: one hotplug fires several notifications, and the
// new hardware format is only visible once the session has settled.
- (void) scheduleRelinkInput: (const char*) reason
{
  NSLog(@"Audio configuration changed (%s) - re-linking I/O", reason);
  if (relinkScheduled)
    return;
  relinkScheduled = YES;
  __weak IPlugAUPlayer* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    IPlugAUPlayer* strongSelf = weakSelf;
    if (strongSelf == nil)
      return;
    strongSelf->relinkScheduled = NO;

    BOOL wasRunning = [strongSelf->audioEngine isRunning];
    if (wasRunning)
      [strongSelf->audioEngine stop];

    // Drop EVERY connection, not just the input side: the output leg was wired at the
    // old hardware format (a USB interface at 44.1 kHz keeps stalling the render graph
    // if it still points at 48 kHz), and -linkInputIfPossible / -connectAudioUnitOutput
    // re-establish both against the settled route.
    [strongSelf->audioEngine reset];
    strongSelf->inputConnected = NO; // reset() dropped every connection
    [strongSelf linkInputIfPossible];

    if (wasRunning)
    {
      NSError* err = nil;
      if (![strongSelf->audioEngine startAndReturnError:&err])
        NSLog(@"engine failed to restart: %@", err);
    }
  });
}
#endif

- (instancetype) initWithComponentType: (UInt32) unitComponentType
{
  self = [super init];
  
  if (self)
  {
    audioEngine = [[AVAudioEngine alloc] init];
    componentType = unitComponentType;
  }

  return self;
}

- (void) loadAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                   completion:(void (^) (void))completionBlock
{
  [AVAudioUnit instantiateWithComponentDescription:desc options:0
                                 completionHandler:^(AVAudioUnit* __nullable audioUnit, NSError* __nullable error) {
                                   [self onAudioUnitInstantiated:audioUnit error:error completion:completionBlock];
                                 }];
}

- (void) onAudioUnitInstantiated:(AVAudioUnit* __nullable) audioUnit error:(NSError* __nullable) error completion:(void (^) (void))completionBlock
{
  if (audioUnit == nil)
    return;
  
  avAudioUnit = audioUnit;
  
  self.currentAudioUnit = avAudioUnit.AUAudioUnit;
  
  AVAudioSession* session = [AVAudioSession sharedInstance];
  
#if PLUG_TYPE == 1
  [session setCategory: AVAudioSessionCategoryPlayback error:&error];
#else
  [session setCategory: AVAudioSessionCategoryPlayAndRecord error:&error];
  if (error != nil)
    NSLog(@"Error setting session category: %@", [error localizedDescription]);
#endif
  
  [session setPreferredSampleRate:iplug::DEFAULT_SAMPLE_RATE error:nil];
  [session setPreferredIOBufferDuration:128.0/iplug::DEFAULT_SAMPLE_RATE error:nil];

#if PLUG_TYPE != 1
  // iOS gates ALL audio input - built-in mic and class-compliant USB interfaces alike -
  // behind the microphone permission. Ask up front rather than letting the engine start
  // trigger the alert mid-render. Newer SDKs encode these enum cases as OSTypes
  // ('undt'/'deny'/'grnt'), so print the four characters rather than the raw integer.
  AVAudioSessionRecordPermission perm = [session recordPermission];
  char pc[5] = {(char) (((long) perm >> 24) & 0xFF), (char) (((long) perm >> 16) & 0xFF), (char) (((long) perm >> 8) & 0xFF), (char) ((long) perm & 0xFF), 0};
  NSLog(@"Microphone permission: '%s' (undt=undetermined deny=denied grnt=granted)", pc);
  if (perm == AVAudioSessionRecordPermissionUndetermined)
  {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
      NSLog(@"Microphone permission granted: %d", granted);
    }];
#pragma clang diagnostic pop
  }
#endif

  // Activate BEFORE reading the input/output node hardware formats: with an inactive
  // session the route (and therefore those formats) is not settled yet, and a connected
  // USB interface is not yet the current route.
  BOOL success = [[AVAudioSession sharedInstance] setActive:TRUE error:nil];
  
  if (success == NO)
    NSLog(@"Error activating session: %@", [error localizedDescription]);

  AVAudioMixerNode* mainMixer = [audioEngine mainMixerNode];
  mainMixer.outputVolume = 1;
  [audioEngine attachNode:avAudioUnit];
  
#if PLUG_TYPE != 1
  AVAudioFormat* micInputFormat = [[audioEngine inputNode] inputFormatForBus:0];
  AVAudioFormat* pluginInputFormat = [avAudioUnit inputFormatForBus:0];
#endif

  NSLog(@"Session SR: %i", int(session.sampleRate));
  NSLog(@"Session IO Buffer: %i", int((session.IOBufferDuration * session.sampleRate)+0.5));
  
#if PLUG_TYPE != 1
  NSLog(@"Mic Input SR: %i", int(micInputFormat.sampleRate));
  NSLog(@"Mic Input Chans: %i", micInputFormat.channelCount);
  NSLog(@"Plugin Input SR: %i", int(pluginInputFormat.sampleRate));
  NSLog(@"Plugin Input Chans: %i", pluginInputFormat.channelCount);
#endif
  
#if PLUG_TYPE != 1
  if (pluginInputFormat != nil)
  {
    [self linkInputIfPossible];
  }
#else
  [self connectAudioUnitOutput];
#endif
  
#if PLUG_TYPE != 1
  // Re-link when the hardware route changes (USB interface plugged in / unplugged,
  // Bluetooth switch, sample rate change...). AVAudioEngine stops on input configuration
  // changes; without a restart + reconnect, the plugin keeps running on a stale or
  // unwired input bus.
  __weak IPlugAUPlayer* weakSelf = self;
  [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                    object:audioEngine
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification* note) {
    [weakSelf scheduleRelinkInput: "engine configuration change"];
  }];
  [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification* note) {
    [weakSelf scheduleRelinkInput: "session route change"];
  }];
  // HAL tripwires below AVAudioSession: hotplug and default-input flips fire here even
  // when the session layer stays quiet (observed: IK TONEX ONE was connected but the
  // app never saw a route change worth re-linking on).
  AudioObjectPropertyAddress halDevsAddr = {kIPlugHardwarePropDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListenerBlock(kIPlugAudioObjectSystemObject, &halDevsAddr, dispatch_get_main_queue(), ^(UInt32 nAddresses, const AudioObjectPropertyAddress* addresses) {
    [weakSelf scheduleRelinkInput: "HAL devices changed"];
  });
  AudioObjectPropertyAddress halDefInAddr = {kIPlugHardwarePropDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListenerBlock(kIPlugAudioObjectSystemObject, &halDefInAddr, dispatch_get_main_queue(), ^(UInt32 nAddresses, const AudioObjectPropertyAddress* addresses) {
    [weakSelf scheduleRelinkInput: "HAL default input changed"];
  });
#endif
  
  if (![audioEngine startAndReturnError:&error])
    NSLog(@"engine failed to start: %@", error);
  
  completionBlock();
}

@end

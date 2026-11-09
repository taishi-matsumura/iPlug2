 /*
 ==============================================================================
 
 This file is part of the iPlug 2 library. Copyright (C) the iPlug 2 developers. 
 
 See LICENSE.txt for  more info.
 
 ==============================================================================
*/

#import "IPlugAUPlayer.h"
#import <CoreAudio/AudioHardwareBase.h>
#include "IPlugConstants.h"

// The iOS SDK ships CoreAudio's base types but not <CoreAudio/AudioHardware.h>
// (Apple marks that content iOS-available since 2.0, and the symbols link from
// AudioToolbox anyway). Declare just what the input-device diagnostics below use.
extern "C" {
enum {
  kVoLumAudioObjectSystemObject = 1,                                // == kAudioObjectSystemObject
  kVoLumHardwarePropDefaultInputDevice = 'dIn ',                   // == kAudioHardwarePropertyDefaultInputDevice
  kVoLumHardwarePropDevices = 'dev#',                              // == kAudioHardwarePropertyDevices
  kVoLumHardwarePropDefaultOutputDevice = 'dOut',                  // == kAudioHardwarePropertyDefaultOutputDevice
  kVoLumDevicePropStreamConfig = 'sstc',                           // == kAudioDevicePropertyStreamConfiguration
};
extern OSStatus AudioObjectGetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                           UInt32 inQualifierDataSize, const void* inQualifierData,
                                           UInt32* ioDataSize, void* outData);
extern OSStatus AudioObjectGetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                               UInt32 inQualifierDataSize, const void* inQualifierData,
                                               UInt32* outDataSize);
// AudioObjectPropertyListenerBlock lives in <CoreAudio/AudioHardware.h>, which the
// iOS SDK omits; declare the same shape (typedef distinct name to avoid clashing
// with any SDK declaration that leaks in transitively).
typedef void (^VoLumPropertyListenerBlock)(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses);
extern OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                                    dispatch_queue_t inDispatchQueue, VoLumPropertyListenerBlock inListenerBlock);
}
#include "config.h"

#if !__has_feature(objc_arc)
#error This file must be compiled with Arc. Use -fobjc-arc flag
#endif

// Console streaming dies the moment the iPad's USB port goes to a USB audio
// interface, which is exactly when silent-input telemetry is needed. Route the
// diagnostics in this file to a log file inside the app container as well; the
// file can be pulled later with `devicectl device copy from` (appDataContainer).
static void VoLumDiagLog(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void VoLumDiagLog(NSString* fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  NSLog(@"%@", msg);

  static NSString* path = nil;
  static dispatch_once_t pathOnce;
  dispatch_once(&pathOnce, ^{
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* sub = [dirs.firstObject stringByAppendingPathComponent:@"VoLum"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
    path = [sub stringByAppendingPathComponent:@"audio_diag.log"];
  });
  static NSDateFormatter* df = nil;
  static dispatch_once_t dfOnce;
  dispatch_once(&dfOnce, ^{
    df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
  });
  @try
  {
    NSString* line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil)
      [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else
    {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
  }
  @catch (NSException* e)
  {
    NSLog(@"audio_diag.log write failed: %@", e.reason);
  }
}
#define NSLog(...) VoLumDiagLog(__VA_ARGS__)

@implementation IPlugAUPlayer
{
  AVAudioEngine* audioEngine;
  AVAudioUnit* avAudioUnit;
  UInt32 componentType;
#if PLUG_TYPE != 1
  BOOL inputConnected;
  BOOL relinkScheduled;
  BOOL inputTapInstalled;
  BOOL outputTapInstalled;
  AVAudioPlayer* tonePlayerDiag; // retain for the diagnostic tone's lifetime
#endif
}

#if PLUG_TYPE != 1
// Name + transport for whichever HAL device answers a system endpoint selector
// ('dIn '/'dOut'). AVAudioSession's ObjC port objects crash on the real device
// (iOS 26 + the legacy-SDK link patch), so ask CoreAudio directly: a pure C
// path that survives. A USB interface reads transport 'usb '; built-ins 'bltn'.
static void VoLumLogHALDeviceEndpoint(UInt32 propSelector, const char* tag)
{
  AudioObjectID dev = kAudioObjectUnknown;
  UInt32 size = sizeof(dev);
  AudioObjectPropertyAddress selAddr = {propSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kVoLumAudioObjectSystemObject, &selAddr, 0, NULL, &size, &dev) != noErr || dev == kAudioObjectUnknown)
  {
    NSLog(@"No HAL device for %s", tag);
    return;
  }
  char name[256] = {0};
  CFStringRef cfName = NULL;
  size = sizeof(cfName);
  AudioObjectPropertyAddress nameAddr = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(dev, &nameAddr, 0, NULL, &size, &cfName) == noErr && cfName)
  {
    CFStringGetCString(cfName, name, sizeof(name), kCFStringEncodingUTF8);
    CFRelease(cfName);
  }
  UInt32 transport = 0;
  size = sizeof(transport);
  AudioObjectPropertyAddress trAddr = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(dev, &trAddr, 0, NULL, &size, &transport) != noErr)
  {
    trAddr.mScope = kAudioObjectPropertyScopeInput;
    size = sizeof(transport);
    AudioObjectGetPropertyData(dev, &trAddr, 0, NULL, &size, &transport);
  }
  char t[5] = {(char) ((transport >> 24) & 0xFF), (char) ((transport >> 16) & 0xFF), (char) ((transport >> 8) & 0xFF), (char) (transport & 0xFF), 0};
  NSLog(@"HAL %s: '%s' transport '%s'", tag, name, t);
}

// Wire (or re-wire) the hardware input to the plugin's input bus in the input
// node's CURRENT hardware format. External USB interfaces (e.g. IK TONEX ONE)
// report a different format than the built-in mic, and plugging one in while
// running changes it; -linkInputIfPossible is re-run from the config/route
// observers so the connection follows the active route instead of staying on
// the format captured at launch.
- (void) linkInputIfPossible
{
  AVAudioFormat* micInputFormat = [[audioEngine inputNode] inputFormatForBus:0];

  // The iOS Simulator can report an invalid input node hardware format
  // (sample rate 0), which makes -[AVAudioEngine connect:to:format:] throw
  // ("IsFormatSampleRateAndChannelCountValid(format)" / "Input HW format is
  // invalid"). Skip the mic connection in that case; the plugin's input bus
  // is then fed silence. A real device reports a valid format once the
  // session is active; a route change retries.
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

  // Which PHYSICAL devices own the default input AND output? (A connected USB
  // interface usually steals both; if its phones/line out are not monitored,
  // the user hears "silence" while the input tap proves audio is flowing.)
  VoLumLogHALDeviceEndpoint(kVoLumHardwarePropDefaultInputDevice, "default input");
  VoLumLogHALDeviceEndpoint(kVoLumHardwarePropDefaultOutputDevice, "default output");
  [self logHALInputDevices];
  [self installInputLevelTap];
}

// Wire the plugin's output side using the CURRENT hardware output format.
// The upstream wiring pins the plugin's own bus format (48 kHz by default);
// when a USB interface runs the session at its native rate (TONEX ONE:
// 44.1 kHz x 2), that stale 48 kHz connection makes the whole render graph
// stall - input node emits nothing, output is silent. Match the hardware.
- (void) connectAudioUnitOutput
{
  AVAudioFormat* outputHWFormat = [audioEngine.outputNode inputFormatForBus:0];
  if (outputHWFormat == nil || outputHWFormat.sampleRate <= 0.0 || outputHWFormat.channelCount == 0)
    outputHWFormat = [avAudioUnit outputFormatForBus:0]; // simulator / no settled route: plugin format
  AVAudioFormat* auIn = [avAudioUnit inputFormatForBus:0];
  AVAudioFormat* auOut = [avAudioUnit outputFormatForBus:0];
  NSLog(@"Plugin output bus wired to %g Hz x %u ch (AU bus fmt now in %g/%u out %g/%u)", outputHWFormat.sampleRate,
        (unsigned) outputHWFormat.channelCount, auIn.sampleRate, (unsigned) auIn.channelCount,
        auOut.sampleRate, (unsigned) auOut.channelCount);

  auto numOutputBuses = [avAudioUnit numberOfOutputs];
  AVAudioMixerNode* mainMixer = [audioEngine mainMixerNode];
  // Always route AU -> mainMixer -> outputNode. The transparent mixer gives
  // us a measurable tap point for "did the plugin's audio actually leave
  // toward the hardware" and matches the multi-bus case for free.
  if (numOutputBuses > 1)
  {
    for (int busIdx = 0; busIdx < numOutputBuses; busIdx++)
      [audioEngine connect:avAudioUnit to:mainMixer fromBus:busIdx toBus:[mainMixer nextAvailableInputBus] format:outputHWFormat];
  }
  else
  {
    [audioEngine connect:avAudioUnit to:mainMixer format:outputHWFormat];
  }
  [audioEngine connect:mainMixer to:audioEngine.outputNode format:outputHWFormat];
  // The mixer's own outputFormatForBus can come back zeroed before the engine
  // starts, so tap explicitly at the format just connected.
  [self installOutputLevelTap:outputHWFormat];
}

// Counterpart of installInputLevelTap: peak level of whatever the engine is
// pushing toward the hardware output. Alive output tap + silent device =
// device-side playback problem; dead output tap + live input tap = the plugin
// or output wiring is dropping the signal.
- (void) installOutputLevelTap: (AVAudioFormat*)fmt
{
  if (outputTapInstalled)
    return;
  if (fmt == nil || fmt.sampleRate <= 0.0 || fmt.channelCount == 0)
    return;
  AVAudioMixerNode* mainMixer = [audioEngine mainMixerNode];
  @try
  {
    [mainMixer installTapOnBus:0 bufferSize:4096 format:fmt block:^(AVAudioPCMBuffer* buffer, AVAudioTime* whenTime) {
    float peak = 0.f;
    if (buffer.floatChannelData != nullptr)
    {
      for (AVAudioFrameCount c = 0; c < buffer.format.channelCount; ++c)
      {
        const float* data = buffer.floatChannelData[c];
        for (AVAudioFrameCount i = 0; i < buffer.frameLength; ++i)
        {
          float v = fabsf(data[i]);
          if (v > peak)
            peak = v;
        }
      }
    }
    static uint64_t sLastOutLogNs = 0;
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (nowNs - sLastOutLogNs >= 1000000000ull)
    {
      sLastOutLogNs = nowNs;
      const float peakCopy = peak;
      const double sr = fmt.sampleRate;
      const unsigned nCh = (unsigned) fmt.channelCount;
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        float db = peakCopy > 0.f ? 20.f * log10f(peakCopy) : -999.f;
        VoLumDiagLog(@"Output tap peak: %.2f dBFS (fmt %g Hz x %u ch)", db, sr, nCh);
      });
    }
  }];
  }
  @catch (NSException* e)
  {
    NSLog(@"Output tap install failed: %@ / %@", e.name, e.reason);
    return;
  }
  outputTapInstalled = YES;
  NSLog(@"Output level tap installed (%g Hz x %u ch)", fmt.sampleRate, (unsigned) fmt.channelCount);
}

// One-time HAL device census: name + transport + input channel count for every
// device CoreAudio currently sees. Tells a missing/unplugged interface apart
// from a present-but-unrouted one, without touching AVAudioSession's ObjC port
// objects (which crash this legacy-linked binary on iOS 26).
- (void) logHALInputDevices
{
  UInt32 size = 0;
  AudioObjectPropertyAddress devsAddr = {kVoLumHardwarePropDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  OSStatus szErr = AudioObjectGetPropertyDataSize(kVoLumAudioObjectSystemObject, &devsAddr, 0, NULL, &size);
  if (szErr != noErr)
  {
    NSLog(@"HAL: cannot size device list (status %d)", (int) szErr);
    return;
  }
  AudioObjectID ids[16] = {0};
  UInt32 cap = sizeof(ids);
  if (size < cap)
    cap = size;
  if (AudioObjectGetPropertyData(kVoLumAudioObjectSystemObject, &devsAddr, 0, NULL, &cap, ids) != noErr)
  {
    NSLog(@"HAL: cannot read device list");
    return;
  }
  NSLog(@"HAL: %u devices visible", (unsigned) (cap / sizeof(AudioObjectID)));
  for (UInt32 i = 0; i < cap / sizeof(AudioObjectID); ++i)
  {
    char name[128] = {0};
    CFStringRef cfName = NULL;
    UInt32 sz = sizeof(cfName);
    AudioObjectPropertyAddress nameAddr = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(ids[i], &nameAddr, 0, NULL, &sz, &cfName) == noErr && cfName)
    {
      CFStringGetCString(cfName, name, sizeof(name), kCFStringEncodingUTF8);
      CFRelease(cfName);
    }

    UInt32 transport = 0;
    sz = sizeof(transport);
    AudioObjectPropertyAddress trAddr = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(ids[i], &trAddr, 0, NULL, &sz, &transport) != noErr)
    {
      trAddr.mScope = kAudioObjectPropertyScopeInput;
      sz = sizeof(transport);
      AudioObjectGetPropertyData(ids[i], &trAddr, 0, NULL, &sz, &transport);
    }
    char t[5] = {(char) ((transport >> 24) & 0xFF), (char) ((transport >> 16) & 0xFF), (char) ((transport >> 8) & 0xFF), (char) (transport & 0xFF), 0};

    // Input-scope stream configuration: buffer count = streams, summed
    // mNumbersOfChannels = total analog input channels this device offers.
    int inStreams = 0, inChans = 0;
    sz = 0;
    AudioObjectPropertyAddress scAddr = {kVoLumDevicePropStreamConfig, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(ids[i], &scAddr, 0, NULL, &sz) == noErr && sz > sizeof(UInt32))
    {
      AudioBufferList* abl = (AudioBufferList*) malloc(sz);
      if (abl && AudioObjectGetPropertyData(ids[i], &scAddr, 0, NULL, &sz, abl) == noErr)
      {
        inStreams = (int) abl->mNumberBuffers;
        for (UInt32 b = 0; b < abl->mNumberBuffers; ++b)
          inChans += (int) abl->mBuffers[b].mNumberChannels;
      }
      free(abl);
    }
    NSLog(@"HAL dev: '%s' transport '%s' inputs: %d streams / %d ch", name, t, inStreams, inChans);
  }
}

// The decisive silent-input discriminator lives in installInputLevelTap below:
// AVAudioSession's port objects crash this binary on iOS 26, and the input
// node's HAL device ID is macOS-only, so a once-per-second peak level from an
// input-node tap is what tells "route is live but the app is muted" apart from
// "the route itself is dead".

// Decisive telemetry: tap the hardware input node and log its peak level once
// per second. "iPad sees the interface but the app gets nothing" (tap silent),
// "the app gets audio but the plugin chain drops it" (tap alive, output dead)
// and "no route at all" are three different bugs; this pinpoints which.
- (void) installInputLevelTap
{
  if (inputTapInstalled)
    return;
  AVAudioFormat* fmt = [audioEngine.inputNode outputFormatForBus:0];
  if (fmt == nil || fmt.sampleRate <= 0.0 || fmt.channelCount == 0)
    return;
  const AVAudioFrameCount maxFrames = 4096;
  [audioEngine.inputNode installTapOnBus:0 bufferSize:maxFrames format:fmt block:^(AVAudioPCMBuffer* buffer, AVAudioTime* whenTime) {
    float peak = 0.f;
    if (buffer.floatChannelData != nullptr)
    {
      for (AVAudioFrameCount c = 0; c < buffer.format.channelCount; ++c)
      {
        const float* data = buffer.floatChannelData[c];
        for (AVAudioFrameCount i = 0; i < buffer.frameLength; ++i)
        {
          float v = fabsf(data[i]);
          if (v > peak)
            peak = v;
        }
      }
    }
    static uint64_t sLastLogNs = 0;
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (nowNs - sLastLogNs >= 1000000000ull)
    {
      sLastLogNs = nowNs;
      const float peakCopy = peak;
      const double sr = fmt.sampleRate;
      const unsigned nCh = (unsigned) fmt.channelCount;
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        float db = peakCopy > 0.f ? 20.f * log10f(peakCopy) : -999.f;
        VoLumDiagLog(@"Input tap peak: %.2f dBFS (fmt %g Hz x %u ch)", db, sr, nCh);
      });
    }
  }];
  inputTapInstalled = YES;
  NSLog(@"Input level tap installed (%g Hz x %u ch)", fmt.sampleRate, (unsigned) fmt.channelCount);
}

// Coalesced re-link: route changes can fire several times per hotplug, and the
// new format is only visible once the session has settled.
- (void) scheduleRelinkInput: (const char*) reason
{
  NSLog(@"Audio configuration changed (%s) - re-linking input", reason);
  if (relinkScheduled)
    return;
  relinkScheduled = YES;
  __weak IPlugAUPlayer* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    IPlugAUPlayer* strongSelf = weakSelf;
    if (strongSelf == nil)
      return;
    strongSelf->relinkScheduled = NO;
    // reset() does NOT remove installed taps - each must come down explicitly,
    // guarded by its flag (removing a nonexistent tap also throws). Formats
    // belong to the old route; -linkInputIfPossible / -connectAudioUnitOutput
    // re-install both against the settled one.
    if (strongSelf->inputTapInstalled)
    {
      [strongSelf->audioEngine.inputNode removeTapOnBus:0];
      strongSelf->inputTapInstalled = NO;
    }
    if (strongSelf->outputTapInstalled)
    {
      [strongSelf->audioEngine.mainMixerNode removeTapOnBus:0];
      strongSelf->outputTapInstalled = NO;
    }
    BOOL wasRunning = [strongSelf->audioEngine isRunning];
    if (wasRunning)
      [strongSelf->audioEngine stop];
    // Drop EVERY connection, not just the input side: the output leg was
    // wired at the old hardware format (a USB interface at 44.1 kHz keeps
    // stalling the render graph if it still points at 48 kHz), and both
    // -linkInputIfPossible and -connectAudioUnitOutput re-establish it
    // against the settled route.
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
  // iOS gates ALL audio input - built-in mic and class-compliant USB interfaces
  // alike - behind the microphone permission. Log the state so a silent-input
  // report can be told apart from a routing problem, and ask up front (rather
  // than letting the engine start trigger the alert mid-render).
  // Newer SDKs encode these enum cases as OSTYpes ('undt'/'deny'/'grnt'), so print
  // the four characters rather than the raw integer.
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

  // iOS 17+ can silently zero the mic/line input (system "input muted" state,
  // surfaced by Control Center / Focus). Read it through the runtime, not a
  // static symbol, so the older min-target link stays happy.
  if (@available(iOS 17.0, *))
  {
    @try
    {
      Class appCls = NSClassFromString(@"AVAudioApplication");
      id appShared = appCls ? [appCls valueForKey:@"sharedInstance"] : nil; // ObjC name; "shared" is Swift-only
      if (appShared)
        NSLog(@"System input mute state: %@", [appShared valueForKey:@"inputMuted"]);
    }
    @catch (NSException* e)
    {
      NSLog(@"System input mute state unavailable: %@", e.reason);
    }
  }
#endif

  // Activate BEFORE reading the input node's hardware format: with an inactive
  // session the route (and therefore the input format) is not settled yet, and
  // a connected USB interface is not yet the current route.
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
  // Re-link the input when the hardware route changes (USB interface plugged
  // in / unplugged, Bluetooth switch, sample rate change...). AVAudioEngine
  // stops on input configuration changes; without a restart + reconnect, the
  // plugin keeps running on a stale or unwired input bus.
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
  // HAL tripwires below AVAudioSession: hotplug and default-input flips fire
  // here even when the session layer stays quiet (observed: TONEX ONE was
  // connected but the app never saw a route change worth re-linking on).
  AudioObjectPropertyAddress halDevsAddr = {kVoLumHardwarePropDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListenerBlock(kVoLumAudioObjectSystemObject, &halDevsAddr, dispatch_get_main_queue(), ^(UInt32 nAddresses, const AudioObjectPropertyAddress* addresses) {
    [weakSelf scheduleRelinkInput: "HAL devices changed"];
  });
  AudioObjectPropertyAddress halDefInAddr = {kVoLumHardwarePropDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListenerBlock(kVoLumAudioObjectSystemObject, &halDefInAddr, dispatch_get_main_queue(), ^(UInt32 nAddresses, const AudioObjectPropertyAddress* addresses) {
    [weakSelf scheduleRelinkInput: "HAL default input changed"];
  });
#endif
  
  if (![audioEngine startAndReturnError:&error])
    NSLog(@"engine failed to start: %@", error);
  
#if PLUG_TYPE != 1
  // Diagnostic #2: a tone rendered INSIDE the engine (source node -> mixer ->
  // outputNode) starting ~2.5 s after launch. Compare audibility against the
  // AVAudioPlayer tone below: external tone audible + engine tone silent
  // localizes the mute to the engine's remoteIO output leg.
  {
    AVAudioFormat* outFmt = [audioEngine.outputNode inputFormatForBus:0];
    if (outFmt != nil && outFmt.sampleRate > 0.0)
    {
      const double sr = outFmt.sampleRate;
      const double skipFrames = 2.5 * sr;      // let the session settle first
      const double toneFrames = 2.0 * sr;
      __block double framePos = 0;
      AVAudioSourceNode* toneSrc = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp, AVAudioFrameCount frameCount, AudioBufferList* outputData) {
        UInt32 nFrames = (UInt32) frameCount;
        for (UInt32 ch = 0; ch < outputData->mNumberBuffers; ++ch)
        {
          float* buf = (float*) outputData->mBuffers[ch].mData;
          for (UInt32 f = 0; f < nFrames; ++f)
          {
            double pos = framePos + f;
            double rel = pos - skipFrames;
            float s = 0.f;
            if (rel >= 0.0 && rel < toneFrames)
            {
              double ramp = 0.01 * sr;
              double env = 1.0;
              if (rel < ramp) env = 0.5 - 0.5 * cos(M_PI * rel / ramp);
              if (toneFrames - rel < ramp) env = 0.5 - 0.5 * cos(M_PI * (toneFrames - rel) / ramp);
              s = (float) (env * 0.4 * sin(2.0 * M_PI * 440.0 * rel / sr));
            }
            buf[f] = s;
          }
        }
        framePos += nFrames;
        return noErr;
      }];
      [audioEngine attachNode:toneSrc];
      @try
      {
        [audioEngine connect:toneSrc to:audioEngine.mainMixerNode format:outFmt];
        NSLog(@"Engine tone source attached (fires ~2.5-4.5 s after start)");
      }
      @catch (NSException* e)
      {
        NSLog(@"Engine tone connect failed: %@ / %@", e.name, e.reason);
      }
    }
  }

  // Diagnostic #1: play a 2 s 440 Hz tone through an AVAudioPlayer -
  // an output path completely independent of AVAudioEngine. If the user hears
  // the tone while the engine's own output tap shows signal yet the device is
  // silent, the mute is inside the engine->remoteIO leg, not the session/route.
  {
    enum { kToneSR = 44100, kToneFrames = 2 * 44100 };
    static SInt16 toneSamples[kToneFrames];
    static dispatch_once_t toneOnce;
    dispatch_once(&toneOnce, ^{
      for (int i = 0; i < kToneFrames; ++i)
        toneSamples[i] = (SInt16) (0.3 * 32767.0 * sin((2.0 * M_PI * 440.0 * i) / kToneSR));
    });
    NSMutableData* wav = [NSMutableData data];
    struct { char riff[4] = {'R','I','F','F'}; UInt32 chunkSize; char wave[4] = {'W','A','V','E'};
             char fmt[4] = {'f','m','t',' '}; UInt32 fmtSize; UInt16 fmtTag, channels, sampleRateLo, sampleRateHi;
             UInt32 byteRate; UInt16 blockAlign, bits; char dataHdr[4] = {'d','a','t','a'}; UInt32 dataSize; } hdr;
    hdr.chunkSize = sizeof(hdr) - 8 + sizeof(toneSamples);
    hdr.fmtSize = 16; hdr.fmtTag = 1; hdr.channels = 1;
    hdr.sampleRateLo = kToneSR & 0xFFFF; hdr.sampleRateHi = kToneSR >> 16;
    hdr.byteRate = kToneSR * 2; hdr.blockAlign = 2; hdr.bits = 16;
    hdr.dataSize = sizeof(toneSamples);
    [wav appendBytes:&hdr length:sizeof(hdr)];
    [wav appendBytes:toneSamples length:sizeof(toneSamples)];
    NSError* playerErr = nil;
    AVAudioPlayer* tonePlayer = [[AVAudioPlayer alloc] initWithData:wav error:&playerErr];
    if (playerErr)
      NSLog(@"Tone player init failed: %@", playerErr);
    else
    {
      tonePlayerDiag = tonePlayer;
      tonePlayerDiag.volume = 1.0;
      BOOL played = [tonePlayerDiag play];
      NSLog(@"Diagnostic tone playing: %d (2 s, 440 Hz) engine running: %d", played, [audioEngine isRunning]);
    }
  }
#endif
  
  completionBlock();
}

@end

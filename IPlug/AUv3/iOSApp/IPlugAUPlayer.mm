 /*
 ==============================================================================
 
 This file is part of the iPlug 2 library. Copyright (C) the iPlug 2 developers. 
 
 See LICENSE.txt for  more info.
 
 ==============================================================================
*/

#import "IPlugAUPlayer.h"
#import <objc/message.h> // TEMP DIAGNOSTICS v2 (diagRenderStateToArray:)
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

// ===================== TEMP DIAGNOSTICS v2 - begin (delete wholesale) ========
// Peak dBFS taps only prove "nonzero samples exist"; they cannot show whether
// audible CONTENT travels a path. So each tap also streams its buffer to a
// 16-bit PCM WAV inside the container (pullable with devicectl). Realtime
// blocks only touch a memory ring; a background GCD timer does the file I/O.
#include <cstdio>
#include <cstring>
#include <vector>
#include <atomic>

namespace volum_diag {
enum
{
  kRingFrames = 1 << 16, // 65536 frames ~ 1.5 s per sink
  kMaxSinks = 3,
};

struct Sink
{
  FILE* f = nullptr;
  char tag[12] = {0};
  int ch = 0;
  int sr = 0;
  int wpos = 0;      // frames: ring write cursor
  int rpos = 0;      // frames: ring flush cursor
  long long frames = 0;
  long long dropped = 0;
  long long flushes = 0;
  std::vector<int16_t> ring;
};

static Sink sinks[kMaxSinks];
static char dirPath[512] = {0};
static int16_t dryRing[2][kRingFrames];
static std::atomic<int> dryW {0}, dryR {0};

inline void Init(const char* dir)
{
  if (dir)
    snprintf(dirPath, sizeof(dirPath), "%s", dir);
}

inline void WavHeader(FILE* f, int sr, int ch)
{
  struct
  {
    char riff[4]; UInt32 chunk; char wave[4]; char fmt[4]; UInt32 fmtLen;
    UInt16 tag, channels; UInt32 sr; UInt32 byteRate; UInt16 align, bits;
    char data[4]; UInt32 dataLen;
  } h = {{'R','I','F','F'}, 0xFFFFFFFF, {'W','A','V','E'}, {'f','m','t',' '}, 16, 1, 0, 0, 0, 0, 16, {'d','a','t','a'}, 0xFFFFFFFF};
  h.channels = (UInt16) ch; h.sr = (UInt32) sr; h.byteRate = (UInt32)(sr * ch * 2); h.align = (UInt16)(ch * 2);
  fwrite(&h, sizeof(h), 1, f);
}

inline Sink* SinkFor(const char* tag, int ch, double sr)
{
  Sink* freeSlot = nullptr;
  for (int i = 0; i < kMaxSinks; ++i)
  {
    if (!sinks[i].tag[0]) { freeSlot = &sinks[i]; continue; }
    if (strncmp(sinks[i].tag, tag, sizeof(sinks[i].tag)) == 0) return &sinks[i];
  }
  if (!freeSlot) return nullptr;
  snprintf(freeSlot->tag, sizeof(freeSlot->tag), "%s", tag);
  freeSlot->ch = ch > 2 ? 2 : (ch < 1 ? 1 : ch);
  freeSlot->sr = (int) sr;
  freeSlot->ring.assign((size_t) freeSlot->ch * kRingFrames, 0);
  if (dirPath[0])
  {
    char path[640];
    snprintf(path, sizeof(path), "%s/tap_%s.wav", dirPath, tag);
    freeSlot->f = fopen(path, "wb");
    if (freeSlot->f)
      WavHeader(freeSlot->f, freeSlot->sr, freeSlot->ch);
  }
  return freeSlot;
}

// Called from the audio thread: memory only.
inline void Sample(const char* tag, const float* const* data, int ch, int frames, double sr)
{
  if (!data || frames <= 0 || ch <= 0) return;
  Sink* s = SinkFor(tag, ch, sr);
  if (!s || s->ring.empty()) return;
  const int chs = s->ch;
  const int avail = (s->wpos - s->rpos + kRingFrames) % kRingFrames;
  if (avail + frames >= kRingFrames)
  {
    s->dropped += frames; // ring overrun: the flusher fell behind
    return;
  }
  int16_t* r = s->ring.data();
  int w = s->wpos;
  for (int i = 0; i < frames; ++i)
  {
    for (int c = 0; c < chs; ++c)
    {
      float v = (c < ch && data[c]) ? data[c][i] : 0.f;
      if (v > 1.f) v = 1.f; else if (v < -1.f) v = -1.f;
      r[(size_t) w * chs + c] = (int16_t) (v * 32767.f);
    }
    if (++w == kRingFrames) w = 0;
  }
  s->wpos = w;
  s->frames += frames;
}

// Background flush: file I/O happens here, never on the audio thread.
inline void Flush()
{
  for (int i = 0; i < kMaxSinks; ++i)
  {
    Sink* s = &sinks[i];
    if (!s->f || s->ring.empty()) continue;
    int n = (s->wpos - s->rpos + kRingFrames) % kRingFrames;
    if (n <= 0) continue;
    const int chs = s->ch;
    int from = s->rpos;
    if (from + n <= kRingFrames)
      fwrite(&s->ring[(size_t) from * chs], sizeof(int16_t), (size_t) n * chs, s->f);
    else
    {
      int head = kRingFrames - from;
      fwrite(&s->ring[(size_t) from * chs], sizeof(int16_t), (size_t) head * chs, s->f);
      fwrite(&s->ring[0], sizeof(int16_t), (size_t) (n - head) * chs, s->f);
    }
    fflush(s->f);
    s->rpos = s->wpos;
    s->flushes++;
  }
}

inline void Status(char* out, int cap, long long nowSec)
{
  static long long lastSec = -1;
  if (nowSec == lastSec) return;
  lastSec = nowSec;
  for (int i = 0; i < kMaxSinks; ++i)
  {
    Sink* s = &sinks[i];
    if (!s->tag[0]) continue;
    snprintf(out, cap, "tap '%s' frames %lld dropped %lld flushes %lld file %s sr %d ch %d", s->tag, s->frames, s->dropped,
             s->flushes, s->f ? "open" : "MISSING", s->sr, s->ch);
    return; // one sink per tick keeps the log readable
  }
  out[0] = 0;
}

// Faint dry DI passthrough: input tap snapshot -> source node playback.
inline void FeedDry(const float* const* data, int ch, int frames)
{
  if (!data || frames <= 0) return;
  int w = dryW.load(std::memory_order_relaxed);
  for (int i = 0; i < frames; ++i)
  {
    for (int c = 0; c < 2; ++c)
    {
      float v = (c < ch && data[c]) ? data[c][i] : (ch > 0 ? data[0][i] : 0.f);
      if (v > 1.f) v = 1.f; else if (v < -1.f) v = -1.f;
      dryRing[c][w] = (int16_t) (v * 32767.f);
    }
    if (++w == kRingFrames) w = 0;
  }
  dryW.store(w, std::memory_order_relaxed);
}

inline void PopDry(AudioBufferList* io, int frames, float gain)
{
  if (!io) return;
  int r = dryR.load(std::memory_order_relaxed);
  int w = dryW.load(std::memory_order_relaxed);
  int avail = (w - r + kRingFrames) % kRingFrames;
  if (avail < frames)
  {
    r = (w - frames + kRingFrames) % kRingFrames; // under-run: realign, brief artefact is fine
    dryR.store(r, std::memory_order_relaxed);
  }
  for (UInt32 b = 0; b < io->mNumberBuffers; ++b)
  {
    float* dst = (float*) io->mBuffers[b].mData;
    const int16_t* src = dryRing[b < 2 ? b : 1];
    for (int i = 0; i < frames; ++i)
      dst[i] = (float) src[(r + i) % kRingFrames] * (gain / 32767.f);
  }
  dryR.store((r + frames) % kRingFrames, std::memory_order_relaxed);
}
} // namespace volum_diag
// ===================== TEMP DIAGNOSTICS v2 - end ===========================

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
  // ---- TEMP DIAGNOSTICS v2 (remove wholesale) ----
  BOOL auTapInstalled;      // tap on the AU's own output bus 0
  BOOL dryPathConnected;    // faint DI source node attached once
  AVAudioSourceNode* drySrcDiag;
  volatile BOOL beepGate;   // render block reads this on the audio thread
  int beepIndexDiag;        // beeps fired so far
  uint64_t beepStartNs;     // t=0 for the TONE BEGIN/END stamps
  dispatch_source_t beepTimerDiag;
  dispatch_source_t tapFlushDiag;
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

  // TEMP DIAGNOSTICS v2: this method runs again on every relink. If each relink
  // ADDS a mixer input bus instead of reusing one, the AU is fed into several
  // dead buses and only one is audible - worth a line in the log.
  VoLumDiagLog(@"Mixer input buses after connect: nextAvailable=%u (AU buses %ld)", (unsigned) [mainMixer nextAvailableInputBus],
               (long) numOutputBuses);

  // TEMP DIAGNOSTICS v2: tap the AU's own output bus as well, so "AU silent"
  // can be separated from "mixer/outputNode silent".
  [self installAULevelTap:outputHWFormat];

  // TEMP DIAGNOSTICS v2: faint clean DI through a source node playing back the
  // input-tap snapshot. Deliberately NOT a second live feed of inputNode: an
  // extra inputNode consumer could change how the engine drives the input and
  // sabotage the very path under test.
  if (!dryPathConnected && outputHWFormat != nil && outputHWFormat.sampleRate > 0.0 && outputHWFormat.channelCount > 0)
  {
    @try
    {
      if (drySrcDiag == nil)
      {
        drySrcDiag = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                                                                             AVAudioFrameCount frameCount, AudioBufferList* outputData) {
          if (frameCount == 0) return noErr;
          volum_diag::PopDry(outputData, (int) frameCount, 0.18f); // quiet on purpose: audible, never masking
          return noErr;
        }];
        [audioEngine attachNode:drySrcDiag];
      }
      [audioEngine connect:drySrcDiag to:audioEngine.mainMixerNode format:outputHWFormat];
      dryPathConnected = YES;
      VoLumDiagLog(@"dry-di: DI source node attached at %g Hz x %u ch", outputHWFormat.sampleRate,
                   (unsigned) outputHWFormat.channelCount);
    }
    @catch (NSException* e)
    {
      VoLumDiagLog(@"dry-di: FAILED %@ / %@ (cannot by itself silence the amp path)", e.name, e.reason);
    }
  }
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
    if (buffer.floatChannelData != nullptr)
      volum_diag::Sample("tap_mix", (const float* const*) buffer.floatChannelData, (int) buffer.format.channelCount,
                         (int) buffer.frameLength, buffer.format.sampleRate); // TEMP DIAGNOSTICS v2
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
    if (buffer.floatChannelData != nullptr)
    {
      volum_diag::Sample("tap_in", (const float* const*) buffer.floatChannelData, (int) buffer.format.channelCount,
                         (int) buffer.frameLength, buffer.format.sampleRate); // TEMP DIAGNOSTICS v2
      volum_diag::FeedDry((const float* const*) buffer.floatChannelData, (int) buffer.format.channelCount,
                          (int) buffer.frameLength); // TEMP DIAGNOSTICS v2 (faint DI playback)
    }
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

#if TARGET_OS_IOS
// TEMP DIAGNOSTICS v2: the decisive question left open by the level taps is
// WHICH PHYSICAL output the session is actually rendering to. HAL device
// queries answer 0 devices from inside this sandbox, so ask AVAudioSession's
// currentRoute instead (reading the proxies is ordinary API; the crash seen
// earlier came from instantiating port objects, which this does not do).
- (void) logSessionRoute: (NSString*) when
{
  @try
  {
    AVAudioSessionRouteDescription* route = [[AVAudioSession sharedInstance] currentRoute];
    NSMutableString* outs = [NSMutableString string];
    for (AVAudioSessionPortDescription* p in route.outputs)
      [outs appendFormat:@"[%@/%@ ch=%lu]", p.portName, p.portType, (unsigned long) p.channels.count];
    NSMutableString* ins = [NSMutableString string];
    for (AVAudioSessionPortDescription* p in route.inputs)
      [ins appendFormat:@"[%@/%@ ch=%lu]", p.portName, p.portType, (unsigned long) p.channels.count];
    VoLumDiagLog(@"Session route %@: OUT=%@ IN=%@ vol=%.2f otherAudio=%d SR=%.0f", when, outs, ins,
                 [[AVAudioSession sharedInstance] outputVolume], [[AVAudioSession sharedInstance] isOtherAudioPlaying],
                 [[AVAudioSession sharedInstance] sampleRate]);
  }
  @catch (NSException* e)
  {
    VoLumDiagLog(@"Session route probe (%@) failed: %@ / %@", when, e.name, e.reason);
  }
}
#endif

// TEMP DIAGNOSTICS v2: tap the AU's own output bus 0. Answers "is the plug
// printing audio?" separately from "is the mixer printing audio?".
- (void) installAULevelTap: (AVAudioFormat*)fmt
{
  if (auTapInstalled)
    return;
  if (fmt == nil || fmt.sampleRate <= 0.0 || fmt.channelCount == 0)
    return;
  @try
  {
    [avAudioUnit installTapOnBus:0 bufferSize:4096 format:fmt block:^(AVAudioPCMBuffer* buffer, AVAudioTime* whenTime) {
    if (buffer.floatChannelData != nullptr)
      volum_diag::Sample("tap_au", (const float* const*) buffer.floatChannelData, (int) buffer.format.channelCount,
                         (int) buffer.frameLength, buffer.format.sampleRate);
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
    static uint64_t sLastAuLogNs = 0;
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (nowNs - sLastAuLogNs >= 1000000000ull)
    {
      sLastAuLogNs = nowNs;
      const float peakCopy = peak;
      const double sr = fmt.sampleRate;
      const unsigned nCh = (unsigned) fmt.channelCount;
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        float db = peakCopy > 0.f ? 20.f * log10f(peakCopy) : -999.f;
        VoLumDiagLog(@"AU tap peak: %.2f dBFS (fmt %g Hz x %u ch)", db, sr, nCh);
      });
    }
  }];
  }
  @catch (NSException* e)
  {
    VoLumDiagLog(@"AU tap install failed: %@ / %@", e.name, e.reason);
    return;
  }
  auTapInstalled = YES;
  VoLumDiagLog(@"AU output bus tap installed (%g Hz x %u ch)", fmt.sampleRate, (unsigned) fmt.channelCount);
}

// TEMP DIAGNOSTICS v2: ring-buffer WAV capture needs a non-realtime flusher.
- (void) startTapFlushTimer
{
  if (tapFlushDiag)
    return;
  NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString* sub = [dirs.firstObject stringByAppendingPathComponent:@"VoLum"];
  [[NSFileManager defaultManager] createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
  volum_diag::Init(sub.UTF8String);
  VoLumDiagLog(@"tap WAV directory: %@", sub);

  tapFlushDiag = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(tapFlushDiag, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 200), NSEC_PER_MSEC * 200, NSEC_PER_MSEC * 50);
  dispatch_source_set_event_handler(tapFlushDiag, ^{
    volum_diag::Flush();
    char line[256];
    volum_diag::Status(line, sizeof(line), (long long) (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / NSEC_PER_SEC));
    if (line[0])
      VoLumDiagLog(@"tap stat: %@", [NSString stringWithUTF8String: line]);
  });
  // dispatch sources start active; do NOT dispatch_resume.
}

// The AU lives in the AUv3 extension target, a separate link unit, so it only
// EXPOSES the numbers and the app logs them here. Handoff hypothesis 5: does
// the plug Prepare() at the negotiated rate or keep its prewarmed 48 kHz?
- (void) logAURenderState
{
  SEL sel = NSSelectorFromString(@"diagRenderStateToArray:");
  if (![avAudioUnit.AUAudioUnit respondsToSelector:sel])
  {
    VoLumDiagLog(@"AU render state: probe not available");
    return;
  }
  NSMutableArray* st = [NSMutableArray array];
  ((void (*)(id, SEL, id)) objc_msgSend)(avAudioUnit.AUAudioUnit, sel, st);
  if (st.count != 3)
    return;
  VoLumDiagLog(@"AU render state: bus SR %g, output buses %d, plug SR after Prepare %d; AU bus in %g/%u out %g/%u",
               [st[0] doubleValue], (int) [st[1] unsignedIntValue], (int) [st[2] longValue],
               [avAudioUnit inputFormatForBus: 0].sampleRate, (unsigned) [avAudioUnit inputFormatForBus: 0].channelCount,
               [avAudioUnit outputFormatForBus: 0].sampleRate, (unsigned) [avAudioUnit outputFormatForBus: 0].channelCount);
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
    if (strongSelf->auTapInstalled) // TEMP DIAGNOSTICS v2
    {
      [strongSelf->avAudioUnit removeTapOnBus:0];
      strongSelf->auTapInstalled = NO;
    }
    strongSelf->dryPathConnected = NO; // reset() dropped this edge; re-wired in -connectAudioUnitOutput
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
#if TARGET_OS_IOS
    [strongSelf logSessionRoute: @"after relink"]; // TEMP DIAGNOSTICS v2
#endif
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
  // TEMP DIAGNOSTICS v2: start the WAV flusher, then snapshot the route and
  // the AU's negotiated render state.
  [self startTapFlushTimer];
#if TARGET_OS_IOS
  [self logSessionRoute: @"at launch"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self logSessionRoute: @"t=6 s"];
  });
#endif
  [self logAURenderState];
#endif
  
#if PLUG_TYPE != 1
  // TEMP DIAGNOSTICS v2: PERIODIC 0.4 s 440 Hz beeps every 3 s from t=2.5 s
  // (15 beeps, ~t=46 s). A one-shot tone only proves the output leg was alive
  // once; the reported silence lasts >= 10 s, so the user counts WHICH beeps
  // are audible: "all 15" = the output leg works throughout and the amp's own
  // content is the problem; "0 of 15" = the engine's output leg never reaches
  // the audible device; "some" = a route/relink event kills it mid-run.
  {
    AVAudioFormat* outFmt = [audioEngine.outputNode inputFormatForBus:0];
    if (outFmt != nil && outFmt.sampleRate > 0.0)
    {
      const double sr = outFmt.sampleRate;
      const double skipFrames = 0.0;      // gate decides when it sounds
      const double toneFrames = 1e18;    // gate decides how long
      __block double framePos = 0;
      __weak IPlugAUPlayer* weakPlayer = self;
      AVAudioSourceNode* toneSrc2 = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp, AVAudioFrameCount frameCount, AudioBufferList* outputData) {
        IPlugAUPlayer* p = weakPlayer;
        const BOOL on = (p != nil) ? p->beepGate : NO;
        UInt32 nFrames = (UInt32) frameCount;
        for (UInt32 ch = 0; ch < outputData->mNumberBuffers; ++ch)
        {
          float* buf = (float*) outputData->mBuffers[ch].mData;
          for (UInt32 f = 0; f < nFrames; ++f)
          {
            float s = 0.f;
            if (on)
            {
              const double pos = framePos + f;
              s = (float) (0.35 * sin(2.0 * M_PI * 440.0 * pos / sr));
            }
            buf[f] = s;
          }
        }
        framePos += nFrames;
        return noErr;
      }];
      [audioEngine attachNode:toneSrc2];
      @try
      {
        [audioEngine connect:toneSrc2 to:audioEngine.mainMixerNode format:outFmt];
        VoLumDiagLog(@"beep: source node attached (0.4 s 440 Hz every 3 s, 15x from t=2.5 s)");
      }
      @catch (NSException* e)
      {
        VoLumDiagLog(@"beep: source connect failed: %@ / %@", e.name, e.reason);
      }
      beepStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      beepIndexDiag = 0;
      beepGate = NO;
      beepTimerDiag = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
      dispatch_source_set_timer(beepTimerDiag, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (2.5 * NSEC_PER_SEC)), NSEC_PER_SEC * 3,
                                NSEC_PER_MSEC * 20);
      dispatch_source_set_event_handler(beepTimerDiag, ^{
        IPlugAUPlayer* p = weakPlayer;
        if (p == nil)
          return;
        if (p->beepIndexDiag >= 15)
        {
          dispatch_source_cancel(p->beepTimerDiag);
          p->beepTimerDiag = NULL;
          VoLumDiagLog(@"beep: finished after 15 beeps");
          return;
        }
        p->beepIndexDiag++;
        p->beepGate = YES;
        double t = (double) (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - p->beepStartNs) / 1e9;
        VoLumDiagLog(@"TONE BEGIN %d/15 t=%.1f s", p->beepIndexDiag, t);
#if TARGET_OS_IOS
        [p logSessionRoute: @"before beep"];
#endif
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          IPlugAUPlayer* q = weakPlayer;
          if (q == nil)
            return;
          q->beepGate = NO;
          double t2 = (double) (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - q->beepStartNs) / 1e9;
          VoLumDiagLog(@"TONE END %d/15 t=%.1f s gate was %d", q->beepIndexDiag, t2, (int) q->beepGate);
        });
      });
      // dispatch sources are created active: no dispatch_resume here.
    }
  }

  // Old one-shot engine tone (kept disabled in form, removed with v2 cleanup).
  {
    AVAudioFormat* outFmt = [audioEngine.outputNode inputFormatForBus:0];
    if (NO)
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

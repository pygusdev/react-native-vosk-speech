#import "Vosk.h"
#import "RNVoskModel.h"
#import "Vosk-API.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <vector> // added for float32 -> int16 conversion

// Specific key to detect execution on the processing queue
static void *kVoskProcessingQueueKey = &kVoskProcessingQueueKey;

@implementation Vosk {
  // État interne migré depuis Swift
  RNVoskModel *_Nullable _currentModel;
  VoskRecognizer *_Nullable _recognizer;
  AVAudioEngine *_audioEngine;
  AVAudioInputNode *_inputNode;
  AVAudioFormat *_formatInput;
  dispatch_queue_t _processingQueue;
  NSString *_Nullable _lastPartial;
  dispatch_source_t _Nullable _timeoutSource; // high-performance GCD timer
  BOOL _isRunning; // protects use of recognizer after stop
  BOOL _isStarting; // prevents concurrent start
  BOOL _tapInstalled; // track tap installation
  BOOL _pendingTap; // indicates we are retrying tap installation
  int _tapRetryCount; // retry counter
  // Recording support
  NSString *_Nullable _recordingPath;
  NSString *_Nullable _recordingFormat;
  FILE *_Nullable _audioFile;
  uint32_t _totalBytesWritten;
  double _recordingSampleRate;
  BOOL _preserveAudioSessionOnStop;
}
RCT_EXPORT_MODULE()

- (instancetype)init {
  if ((self = [super init])) {
    _processingQueue =
        dispatch_queue_create("recognizerQueue", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_processingQueue, kVoskProcessingQueueKey,
                                kVoskProcessingQueueKey, NULL);
    // Lazy initialization to avoid triggering microphone permission prompt
    _audioEngine = nil;
    _inputNode = nil;
    _formatInput = nil;
    _recognizer = NULL;
    _currentModel = nil;
    _lastPartial = nil;
    _timeoutSource = nil;
    _isRunning = NO;
    _isStarting = NO;
    _tapInstalled = NO;
    _pendingTap = NO;
    _tapRetryCount = 0;
    _preserveAudioSessionOnStop = NO;
  }
  return self;
}

- (void)dealloc {
  if (_recognizer) {
    vosk_recognizer_free(_recognizer);
    _recognizer = NULL;
  }
}

- (NSArray<NSString *> *)supportedEvents {
  return @[
    @"onError", @"onResult", @"onFinalResult", @"onPartialResult", @"onTimeout",
    @"onVolumeChanged"
  ];
}

- (NSInteger)scoreDataSource:(AVAudioSessionDataSourceDescription *)dataSource {
  NSInteger score = 0;
  if ([dataSource.orientation isEqualToString:AVAudioSessionOrientationFront]) score += 60;
  if ([dataSource.orientation isEqualToString:AVAudioSessionOrientationTop]) score += 45;
  if ([dataSource.location isEqualToString:AVAudioSessionLocationUpper]) score += 30;
  if ([dataSource.orientation isEqualToString:AVAudioSessionOrientationBottom]) score -= 20;
  if ([dataSource.supportedPolarPatterns containsObject:AVAudioSessionPolarPatternCardioid]) score += 15;
  else if ([dataSource.supportedPolarPatterns containsObject:AVAudioSessionPolarPatternSubcardioid]) score += 10;
  return score;
}

- (NSString *)describeDataSource:(AVAudioSessionDataSourceDescription *)dataSource {
  if (!dataSource) return @"(none)";
  return [NSString stringWithFormat:@"%@ loc=%@ orient=%@ pattern=%@",
          dataSource.dataSourceName ?: @"unknown",
          dataSource.location ?: @"unknown",
          dataSource.orientation ?: @"unknown",
          dataSource.selectedPolarPattern ?: dataSource.preferredPolarPattern ?: @"none"];
}

- (void)configurePreferredInputRoute:(AVAudioSession *)audioSession {
  NSArray<AVAudioSessionPortDescription *> *availableInputs = audioSession.availableInputs;
  if (availableInputs.count == 0) {
    NSLog(@"[Vosk] No available input ports reported by AVAudioSession.");
    return;
  }

  AVAudioSessionPortDescription *builtInMic = nil;
  for (AVAudioSessionPortDescription *port in availableInputs) {
    if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
      builtInMic = port;
      break;
    }
  }

  if (!builtInMic) {
    AVAudioSessionPortDescription *currentInput = audioSession.currentRoute.inputs.firstObject;
    NSLog(@"[Vosk] Built-in mic not available. Current input port=%@ selectedDataSource=%@",
          currentInput.portType ?: @"unknown",
          [self describeDataSource:currentInput.selectedDataSource]);
    return;
  }

  NSError *portErr = nil;
  if (![audioSession setPreferredInput:builtInMic error:&portErr]) {
    NSLog(@"[Vosk] Failed to prefer built-in mic: %@", portErr.localizedDescription ?: @"unknown");
  }

  AVAudioSessionDataSourceDescription *bestDataSource = nil;
  NSInteger bestScore = NSIntegerMin;
  for (AVAudioSessionDataSourceDescription *candidate in builtInMic.dataSources) {
    NSInteger score = [self scoreDataSource:candidate];
    if (score > bestScore) {
      bestScore = score;
      bestDataSource = candidate;
    }
  }

  if (bestDataSource) {
    NSError *dataSourceErr = nil;
    if (![builtInMic setPreferredDataSource:bestDataSource error:&dataSourceErr]) {
      NSLog(@"[Vosk] Failed to prefer data source %@: %@",
            bestDataSource.dataSourceName ?: @"unknown",
            dataSourceErr.localizedDescription ?: @"unknown");
    }

    NSArray<AVAudioSessionPolarPattern> *patterns = bestDataSource.supportedPolarPatterns;
    AVAudioSessionPolarPattern preferredPattern = nil;
    if ([patterns containsObject:AVAudioSessionPolarPatternCardioid]) {
      preferredPattern = AVAudioSessionPolarPatternCardioid;
    } else if ([patterns containsObject:AVAudioSessionPolarPatternSubcardioid]) {
      preferredPattern = AVAudioSessionPolarPatternSubcardioid;
    }

    if (preferredPattern) {
      NSError *patternErr = nil;
      if (![bestDataSource setPreferredPolarPattern:preferredPattern error:&patternErr]) {
        NSLog(@"[Vosk] Failed to prefer polar pattern %@ on %@: %@",
              preferredPattern,
              bestDataSource.dataSourceName ?: @"unknown",
              patternErr.localizedDescription ?: @"unknown");
      }
    }

    NSError *sessionDataSourceErr = nil;
    if (![audioSession setInputDataSource:bestDataSource error:&sessionDataSourceErr]) {
      NSLog(@"[Vosk] Failed to activate input data source %@: %@",
            bestDataSource.dataSourceName ?: @"unknown",
            sessionDataSourceErr.localizedDescription ?: @"unknown");
    }
  }

}

- (void)loadModel:(nonnull NSString *)path
          resolve:(nonnull RCTPromiseResolveBlock)resolve
           reject:(nonnull RCTPromiseRejectBlock)reject {
  // Unload the current model if any
  _currentModel = nil;
  NSError *err = nil;
  RNVoskModel *model = [[RNVoskModel alloc] initWithName:path error:&err];
  if (model && !err) {
    _currentModel = model;
    resolve(nil);
  } else {
    reject(@"loadModel", err.localizedDescription ?: @"Failed to load model",
           err);
  }
}

- (void)start:(JS::NativeVosk::VoskOptions &)options
      resolve:(nonnull RCTPromiseResolveBlock)resolve
       reject:(nonnull RCTPromiseRejectBlock)reject {
  if (_currentModel == nil) {
    reject(@"start", @"Model not loaded", nil);
    return;
  }
  if (_isStarting || _isRunning) {
    reject(@"start", @"Recognizer already starting or running", nil);
    return;
  }
  _isStarting = YES;
  _tapRetryCount = 0;
  _pendingTap = NO;
  
  // Lazy initialization of audio engine to avoid permission prompt at module load
  if (!_audioEngine) {
    _audioEngine = [AVAudioEngine new];
  }
  if (!_inputNode) {
    _inputNode = _audioEngine.inputNode;
  }
  
  AVAudioSession *audioSession = [AVAudioSession sharedInstance];
  AVAudioSessionCategoryOptions captureOptions = 0;
  if (@available(iOS 10.0, *)) {
    captureOptions = AVAudioSessionCategoryOptionDefaultToSpeaker;
  }

  // Extract options (grammar, timeout, recording) from the codegen structure
  NSArray<NSString *> *grammar = nil;
  double timeoutMs = -1;
  {
    auto gVec = options.grammar();
    if (gVec) {
      NSMutableArray<NSString *> *tmp = [NSMutableArray new];
      size_t count = gVec->size();
      for (size_t i = 0; i < count; ++i) {
        NSString *s = gVec->at(static_cast<int>(i));
        if (s) [tmp addObject:s];
      }
      grammar = tmp.count > 0 ? tmp : nil;
    }
  }
  if (options.timeout()) {
    timeoutMs = *(options.timeout());
  }
  // Reset to default (false) every start — caller must opt-in each time
  _preserveAudioSessionOnStop = NO;
  if (options.preserveAudioSessionOnStop()) {
    _preserveAudioSessionOnStop = *(options.preserveAudioSessionOnStop()) ? YES : NO;
  }
  NSString *recordingPath = nil;
  NSString *recordingFormat = @"wav";
  {
    NSString *rp = options.recordingPath();
    if (rp) recordingPath = rp;
    NSString *rf = options.recordingFormat();
    if (rf) recordingFormat = rf;
  }

  // Configure session category first (allowed even before permission)
  NSError *catErr = nil;
  @try {
    if (@available(iOS 10.0, *)) {
      [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                           mode:AVAudioSessionModeVoiceChat
                        options:captureOptions
                          error:&catErr];
    } else {
      [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&catErr];
    }
    if (catErr) {
      NSString *msg = [NSString stringWithFormat:@"Audio session category error: %@", catErr.localizedDescription];
      [self emitOnError:msg];
      _isStarting = NO;
      reject(@"start", msg, catErr);
      return;
    }
  } @catch (NSException *ex) {
    NSString *msg = [NSString stringWithFormat:@"Exception setting category: %@", ex.reason ?: @"unknown"]; 
    [self emitOnError:msg];
    _isStarting = NO;
    reject(@"start", msg, nil);
    return;
  }

  // Request permission BEFORE doing heavy work
  [audioSession requestRecordPermission:^(BOOL granted) {
    if (!granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = @"Microphone permission denied";
        [self emitOnError:msg];
        self->_isStarting = NO;
        reject(@"start", msg, nil);
      });
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ // proceed on main
      NSError *prefErr = nil;
      [audioSession setPreferredInputNumberOfChannels:1 error:&prefErr];
      if (prefErr) {
        NSLog(@"[Vosk] Preferred mono input not honored: %@", prefErr.localizedDescription);
      }

      NSError *actErr = nil;
      if (![audioSession setActive:YES error:&actErr]) {
        NSString *msg = [NSString stringWithFormat:@"Failed to activate audio session: %@", actErr.localizedDescription];
        [self emitOnError:msg];
        self->_isStarting = NO;
        reject(@"start", msg, actErr);
        return;
      }

      [self configurePreferredInputRoute:audioSession];

      if (@available(iOS 13.0, *)) {
        NSError *voiceErr = nil;
        if ([self->_inputNode respondsToSelector:@selector(setVoiceProcessingEnabled:error:)]) {
          BOOL enabled = [self->_inputNode setVoiceProcessingEnabled:YES error:&voiceErr];
          if (!enabled || voiceErr) {
            NSLog(@"[Vosk] Voice processing unavailable, continuing without it: %@", voiceErr.localizedDescription ?: @"unknown");
          } else {
            self->_inputNode.voiceProcessingBypassed = NO;
            self->_inputNode.voiceProcessingAGCEnabled = YES;
          }
        }
      }

	  self->_formatInput = [self->_inputNode inputFormatForBus:0];
  const double sampleRate = (self->_formatInput.sampleRate > 0) ? self->_formatInput.sampleRate : 16000.0;
  const AVAudioFrameCount bufferSize = (AVAudioFrameCount)(sampleRate / 40.0);
  self->_isRunning = YES;

  // Open recording file
  if (recordingPath && recordingPath.length > 0) {
    NSString *resolvedPath = recordingPath;
    if (![recordingPath hasPrefix:@"/"]) {
      resolvedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:recordingPath];
    }
    self->_recordingPath = resolvedPath;
    self->_recordingFormat = recordingFormat;
    self->_recordingSampleRate = sampleRate;
    self->_audioFile = fopen([resolvedPath UTF8String], "wb");
    if (!self->_audioFile) {
      NSString *msg = [NSString stringWithFormat:@"Failed to open recording file: %@", resolvedPath];
      [self emitOnError:msg];
      self->_isRunning = NO;
      self->_isStarting = NO;
      self->_recordingPath = nil;
      self->_recordingFormat = nil;
      // Deactivate audio session that was activated above
      NSError *sessErr = nil;
      if (@available(iOS 10.0, *)) {
        [audioSession setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault options:0 error:&sessErr];
      }
      [audioSession setActive:NO
                  withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                        error:&sessErr];
      reject(@"start", msg, nil);
      return;
    }
    if ([recordingFormat isEqualToString:@"wav"]) {
      [self writeWavHeaderPlaceholder];
    }
    self->_totalBytesWritten = 0;
  }

      __weak __typeof(self) weakSelf = self;
      dispatch_async(self->_processingQueue, ^{ // recognizer init off main
        __strong __typeof(self) self = weakSelf;
        if (!self || !self->_isRunning) return;
        if (grammar != nil && grammar.count > 0) {
          NSError *jsonErr = nil;
            NSData *jsonGrammar = [NSJSONSerialization dataWithJSONObject:grammar options:0 error:&jsonErr];
          if (jsonGrammar && !jsonErr) {
            std::string grammarStd((const char *)[jsonGrammar bytes], [jsonGrammar length]);
            self->_recognizer = vosk_recognizer_new_grm(self->_currentModel.model, (float)sampleRate, grammarStd.c_str());
          } else {
            self->_recognizer = vosk_recognizer_new(self->_currentModel.model, (float)sampleRate);
          }
        } else {
          self->_recognizer = vosk_recognizer_new(self->_currentModel.model, (float)sampleRate);
        }
        if (!self->_recognizer) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self emitOnError:@"Recognizer initialization failed (null)"];
            [self stopInternalWithoutEvents:YES];
            reject(@"start", @"Recognizer initialization failed", nil);
          });
          return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ // start engine first
          if (!self->_isRunning) { self->_isStarting = NO; return; }
          [self->_audioEngine prepare];
          NSError *startErr = nil;
          if (![self->_audioEngine startAndReturnError:&startErr]) {
            NSString *msg = [NSString stringWithFormat:@"Failed to start audio engine: %@", startErr.localizedDescription];
            [self emitOnError:msg];
            [self stopInternalWithoutEvents:YES];
            self->_isStarting = NO;
            reject(@"start", msg, startErr);
            return;
          }
          // Timeout timer
          if (timeoutMs >= 0) {
            self->_timeoutSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_processingQueue);
            if (self->_timeoutSource) {
              uint64_t delayNs = (uint64_t)(timeoutMs * 1000000.0);
              __weak __typeof(self) weakSelfTimeout = self;
              dispatch_source_set_timer(self->_timeoutSource, dispatch_time(DISPATCH_TIME_NOW, delayNs), DISPATCH_TIME_FOREVER, 5 * NSEC_PER_MSEC);
              dispatch_source_set_event_handler(self->_timeoutSource, ^{ __strong __typeof(self) selfT = weakSelfTimeout; if (!selfT || !selfT->_isRunning) return; [selfT stopInternalWithoutEvents:YES]; dispatch_async(dispatch_get_main_queue(), ^{ [selfT emitOnTimeout]; }); });
              dispatch_resume(self->_timeoutSource);
            }
          }
          // CONTRACT: Promise resolves here, BEFORE tap is installed.
          // Tap installation requires format stabilization which can take up to
          // ~2.5s with retries. Waiting would make start() unacceptably slow.
          // If tap installation fails later, onError is emitted and
          // stopInternalWithoutEvents cleans up all state.
          // Callers should listen to onError for late failures.
          resolve(nil);
          self->_isStarting = NO;
          self->_pendingTap = YES;
          self->_tapRetryCount = 0;
          [self scheduleTapInstallationWithBufferSize:bufferSize];
        });
      });
    });
  }];
}

// Retry-based tap installer; called on main queue only
- (void)scheduleTapInstallationWithBufferSize:(AVAudioFrameCount)bufferSize {
  if (!_isRunning) { _pendingTap = NO; return; }
  if (_tapInstalled) { _pendingTap = NO; return; }
  if (!_recognizer) { _pendingTap = NO; return; }
  AVAudioFormat *fmt = [_inputNode inputFormatForBus:0];
  double sr = fmt ? fmt.sampleRate : 0.0;
  AVAudioChannelCount ch = fmt ? fmt.channelCount : 0;
  if (sr <= 0.0 || ch == 0) {
    if (_tapRetryCount >= 25) { // ~2.5s at 100ms intervals
      [self emitOnError:@"Unable to obtain valid audio input format (stabilization timeout)"];
      _pendingTap = NO;
      [self stopInternalWithoutEvents:YES];
      return;
    }
    _tapRetryCount++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self scheduleTapInstallationWithBufferSize:bufferSize]; });
    return;
  }
  // Have a valid format now
  __weak __typeof(self) weakSelfTap = self;
  @try {
    [_inputNode installTapOnBus:0 bufferSize:bufferSize format:fmt block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
      __strong __typeof(self) self = weakSelfTap;
      if (!self) return;
      if (!self->_isRunning) return;

      dispatch_async(self->_processingQueue, ^{
        if (!self->_isRunning) return;
        VoskRecognizer *recognizer = self->_recognizer;
        if (!recognizer) return;
        AVAudioFrameCount frames = buffer.frameLength;
        if (frames == 0) return;

        // Normalize audio to PCM16
        const int16_t *pcm16Data = NULL;
        std::vector<int16_t> pcm16Vec;

        if (buffer.int16ChannelData && buffer.int16ChannelData[0]) {
          pcm16Data = buffer.int16ChannelData[0];
        } else if (buffer.floatChannelData && buffer.floatChannelData[0]) {
          pcm16Vec.resize(frames);
          float *ch0 = buffer.floatChannelData[0];
          for (AVAudioFrameCount i = 0; i < frames; ++i) {
            float s = ch0[i];
            if (s > 1.f) s = 1.f;
            else if (s < -1.f) s = -1.f;
            pcm16Vec[i] = (int16_t)lrintf(s * 32767.f);
          }
          pcm16Data = pcm16Vec.data();
        } else {
          return;
        }

        int dataLen = (int)(frames * sizeof(int16_t));

        // Feed to Vosk recognizer
        int accepted = vosk_recognizer_accept_waveform(
          recognizer, (const char *)pcm16Data, (int32_t)dataLen);

        // Write to recording file
        if (self->_audioFile) {
          fwrite(pcm16Data, 1, dataLen, self->_audioFile);
          self->_totalBytesWritten += (uint32_t)dataLen;
        }

        // Compute volume (RMS, linear 0.0–1.0)
        float sumSquares = 0;
        for (AVAudioFrameCount i = 0; i < frames; ++i) {
          float s = (float)pcm16Data[i] / 32767.0f;
          sumSquares += s * s;
        }
        float rms = sqrtf(sumSquares / (float)frames);

        // Emit events
        const char *cstr = NULL;
        BOOL isFinal = NO;
        if (accepted) {
          cstr = vosk_recognizer_result(recognizer);
          isFinal = YES;
        } else {
          cstr = vosk_recognizer_partial_result(recognizer);
        }
        NSString *json = cstr ? [NSString stringWithUTF8String:cstr] : nil;
        double volumeLevel = (double)rms;

        dispatch_async(dispatch_get_main_queue(), ^{
          // Emit volume
          [self emitOnVolumeChanged:@(volumeLevel)];

          // Emit recognition results
          if (!json) return;
          NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
          NSDictionary *parsed = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
            : nil;
          if (![parsed isKindOfClass:[NSDictionary class]]) {
            if (isFinal) { [self emitOnResult:json]; }
            else { [self emitOnPartialResult:json]; }
            return;
          }
          NSString *text = parsed[@"text"];
          NSString *partial = parsed[@"partial"];
          if (isFinal) {
            if (text.length > 0) { [self emitOnResult:text]; }
            self->_lastPartial = nil;
          } else {
            if (partial.length > 0 &&
                (!self->_lastPartial || ![self->_lastPartial isEqualToString:partial])) {
              [self emitOnPartialResult:partial];
            }
            self->_lastPartial = partial ?: self->_lastPartial;
          }
        });
      });
    }];
    _tapInstalled = YES; _pendingTap = NO;
  } @catch (NSException *ex) {
    [self emitOnError:[NSString stringWithFormat:@"Failed to install tap (retry phase): %@", ex.reason ?: @"unknown"]];
    _pendingTap = NO; [self stopInternalWithoutEvents:YES];
  }
}

- (void)stop {
  if (!_isRunning)
    return; // idempotent
  [self stopInternalWithoutEvents:NO];
}

- (void)unload {
  if (_isRunning) {
    [self stopInternalWithoutEvents:NO];
  }
  // Reset all flags to ensure consistent state regardless of running state
  _isStarting = NO;
  _isRunning = NO;
  _tapInstalled = NO;
  _pendingTap = NO;
  _tapRetryCount = 0;
  _currentModel = nil;
}

- (void)addListener:(nonnull NSString *)eventType {
}

- (void)removeListeners:(double)count {
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeVoskSpecJSI>(params);
}

// Internal cleanup
- (void)stopInternalWithoutEvents:(BOOL)withoutEvents {
  // Reset flags immediately to allow restart
  _isRunning = NO;
  _isStarting = NO;
  _tapInstalled = NO;
  _pendingTap = NO;
  
  @try {
    if (_inputNode) {
      [_inputNode removeTapOnBus:0];
    }
  } @catch (...) {
  }

  if (_audioEngine.isRunning) {
    [_audioEngine stop];
    if (!withoutEvents) {
      [self emitOnFinalResult:_lastPartial];
    }
    _lastPartial = nil;
  }
  // Recognizer cleanup after draining processing queue, without deadlock if
  // already on the queue
  if (dispatch_get_specific(kVoskProcessingQueueKey)) {
    if (_recognizer) {
      vosk_recognizer_free(_recognizer);
      _recognizer = NULL;
    }
  } else {
    dispatch_sync(_processingQueue, ^{
      if (self->_recognizer) {
        vosk_recognizer_free(self->_recognizer);
        self->_recognizer = NULL;
      }
    });
  }
  if (_timeoutSource) {
    dispatch_source_cancel(_timeoutSource);
    _timeoutSource = nil;
  }

  // Close recording file (safe: processing queue is drained above)
  if (_audioFile) {
    if ([_recordingFormat isEqualToString:@"wav"]) {
      [self finalizeWavHeader];
    }
    fclose(_audioFile);
    _audioFile = NULL;
  }
  _recordingPath = nil;
  _recordingFormat = nil;

  if (!_preserveAudioSessionOnStop) {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *err = nil;
    if (@available(iOS 10.0, *)) {
      [audioSession setCategory:AVAudioSessionCategoryPlayback
                           mode:AVAudioSessionModeDefault
                        options:0
                          error:&err];
    } else {
      [audioSession setCategory:AVAudioSessionCategoryPlayback error:&err];
    }
    [audioSession
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:&err];
  }
}

// WAV header helpers — values derived from actual sample rate, not hardcoded.
- (void)writeWavHeaderPlaceholder {
  uint8_t header[44] = {0};
  uint32_t sr = (uint32_t)_recordingSampleRate;
  uint16_t channels = 1;
  uint16_t bitsPerSample = 16;
  uint32_t byteRate = sr * channels * bitsPerSample / 8;
  uint16_t blockAlign = channels * bitsPerSample / 8;

  // RIFF
  header[0]='R'; header[1]='I'; header[2]='F'; header[3]='F';
  // ChunkSize placeholder (offset 4) — filled in finalizeWavHeader
  // WAVE
  header[8]='W'; header[9]='A'; header[10]='V'; header[11]='E';
  // fmt
  header[12]='f'; header[13]='m'; header[14]='t'; header[15]=' ';
  header[16]=16; // Subchunk1Size
  header[20]=1;  // AudioFormat = PCM
  header[22]=(uint8_t)(channels & 0xFF);
  // SampleRate (LE)
  header[24]= sr      & 0xFF; header[25]=(sr>>8)  & 0xFF;
  header[26]=(sr>>16) & 0xFF; header[27]=(sr>>24) & 0xFF;
  // ByteRate (LE)
  header[28]= byteRate      & 0xFF; header[29]=(byteRate>>8)  & 0xFF;
  header[30]=(byteRate>>16) & 0xFF; header[31]=(byteRate>>24) & 0xFF;
  // BlockAlign
  header[32]=(uint8_t)(blockAlign & 0xFF);
  // BitsPerSample
  header[34]=(uint8_t)(bitsPerSample & 0xFF);
  // data
  header[36]='d'; header[37]='a'; header[38]='t'; header[39]='a';
  // Subchunk2Size placeholder (offset 40) — filled in finalizeWavHeader

  fwrite(header, 1, 44, _audioFile);
}

- (void)finalizeWavHeader {
  if (!_audioFile) return;
  // ChunkSize = totalBytesWritten + 36
  uint32_t chunkSize = _totalBytesWritten + 36;
  fseek(_audioFile, 4, SEEK_SET);
  fwrite(&chunkSize, 4, 1, _audioFile);
  // Subchunk2Size = totalBytesWritten
  fseek(_audioFile, 40, SEEK_SET);
  fwrite(&_totalBytesWritten, 4, 1, _audioFile);
}

@end

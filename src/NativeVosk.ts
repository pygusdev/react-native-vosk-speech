import type { TurboModule, CodegenTypes } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export type VoskOptions = {
  /**
   * Set of phrases the recognizer will seek on which is the closest one from
   * the record, add `"[unk]"` to the set to recognize phrases striclty.
   */
  grammar?: string[];
  /**
   * Timeout in milliseconds to listen.
   */
  timeout?: number;
  /**
   * Optional file path to persist the captured audio.
   */
  recordingPath?: string;
  /**
   * Recording output format. Defaults to wav when recordingPath is provided.
   */
  recordingFormat?: 'wav' | 'pcm';
  /**
   * Android-only input source hint for the recorder.
   */
  audioSource?: 'voice_recognition' | 'mic';
};

export interface Spec extends TurboModule {
  loadModel: (path: string) => Promise<void>;
  unload: () => void;

  start: (options?: VoskOptions) => Promise<void>;
  stop: () => void;

  addListener: (eventType: string) => void;
  removeListeners: (count: number) => void;

  readonly onResult: CodegenTypes.EventEmitter<string>;
  readonly onPartialResult: CodegenTypes.EventEmitter<string>;
  readonly onFinalResult: CodegenTypes.EventEmitter<string>;
  readonly onError: CodegenTypes.EventEmitter<string>;
  readonly onTimeout: CodegenTypes.EventEmitter<void>;
  readonly onVolumeChanged: CodegenTypes.EventEmitter<number>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Vosk');

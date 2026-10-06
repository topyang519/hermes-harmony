/** One application player. Stream generations isolate late open/end callbacks. */
import { audio } from '@kit.AudioKit';
import { GatewayClient } from './GatewayClient';

export class Player {
  static readonly instance: Player = new Player();
  private renderer: audio.AudioRenderer | null = null;
  private queue: ArrayBuffer[] = [];
  private generation: number = 0;
  private ended: boolean = false;
  private attached: boolean = false;
  private accepting: boolean = false;
  private drainTimer: number = -1;

  attach(): void {
    if (this.attached) {
      return;
    }
    this.attached = true;
    GatewayClient.instance.onTtsStart = (sr: number) => {
      void this.begin(sr);
    };
    GatewayClient.instance.onPcm = (chunk: ArrayBuffer) => {
      if (this.accepting) {
        this.queue.push(chunk);
      }
    };
    GatewayClient.instance.onTtsEnd = (aborted: boolean, _bytes: number) => {
      if (aborted) {
        void this.stop();
      } else {
        this.ended = true;
      }
    };
  }

  async stop(): Promise<void> {
    this.generation += 1;
    this.accepting = false;
    this.queue = [];
    this.ended = true;
    clearTimeout(this.drainTimer);
    this.drainTimer = -1;
    AppStorage.setOrCreate('hermes_speaking', false);
    const prev = this.renderer;
    this.renderer = null;
    await this.release(prev);
  }

  private async release(renderer: audio.AudioRenderer | null): Promise<void> {
    if (!renderer) {
      return;
    }
    try {
      await renderer.stop();
    } catch (_err) {}
    try {
      await renderer.release();
    } catch (_err) {}
  }

  private async begin(sr: number): Promise<void> {
    const epoch = ++this.generation;
    this.accepting = true;
    clearTimeout(this.drainTimer);
    this.drainTimer = -1;
    this.queue = [];
    this.ended = false;
    const prev = this.renderer;
    this.renderer = null;
    await this.release(prev);
    if (epoch !== this.generation) {
      return;
    }
    let renderer: audio.AudioRenderer | null = null;
    try {
      renderer = await audio.createAudioRenderer({
        streamInfo: {
          samplingRate: sr === 24000 ? audio.AudioSamplingRate.SAMPLE_RATE_24000 :
            audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 }
      });
      if (epoch !== this.generation) {
        await this.release(renderer);
        return;
      }
      renderer.on('writeData', (data: ArrayBuffer) => {
        const dst = new Uint8Array(data);
        for (let i = 0; i < dst.length; i++) {
          dst[i] = 0;
        }
        if (epoch !== this.generation) {
          return audio.AudioDataCallbackResult.VALID;
        }
        let offset = 0;
        while (offset < dst.length && this.queue.length > 0) {
          const chunk = this.queue.shift() as ArrayBuffer;
          const src = new Uint8Array(chunk);
          const count = Math.min(src.length, dst.length - offset);
          dst.set(src.subarray(0, count), offset);
          offset += count;
          if (count < src.length) {
            this.queue.unshift(chunk.slice(count));
          }
        }
        if (this.ended && this.queue.length === 0 && this.drainTimer === -1) {
          // Allow the last submitted audio buffer to leave the hardware queue.
          this.drainTimer = setTimeout(() => {
            if (epoch === this.generation) {
              void this.stop();
            }
          }, 250);
        }
        return audio.AudioDataCallbackResult.VALID;
      });
      this.renderer = renderer;
      await renderer.start();
      if (epoch === this.generation) {
        AppStorage.setOrCreate('hermes_speaking', true);
      }
    } catch (_err) {
      await this.release(renderer);
      if (epoch === this.generation) {
        this.renderer = null;
        this.accepting = false;
        this.queue = [];
        AppStorage.setOrCreate('hermes_speaking', false);
        GatewayClient.instance.lastError = '语音播放失败，回复文字仍可阅读';
        GatewayClient.instance.publishUi();
      }
    }
  }
}

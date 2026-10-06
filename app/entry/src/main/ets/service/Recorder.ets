/** Foreground hold-to-talk capture. A release during permission/startup cancels safely. */
import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { GatewayClient } from './GatewayClient';

export class Recorder {
  private capturer: audio.AudioCapturer | null = null;
  private starting: Promise<void> | null = null;
  private stopping: Promise<boolean> | null = null;
  private cancelled: boolean = false;
  private running: boolean = false;
  private wireOpen: boolean = false;
  private startedAt: number = 0;
  private duration: number = 0;

  lastDurationSec(): number {
    return Math.max(1, Math.round(this.duration / 1000));
  }

  async start(context: common.UIAbilityContext, sessionId: string): Promise<void> {
    if (this.starting || this.running || this.stopping) {
      return;
    }
    this.cancelled = false;
    this.duration = 0;
    this.starting = this.open(context, sessionId);
    try {
      await this.starting;
    } finally {
      this.starting = null;
    }
  }

  private async open(context: common.UIAbilityContext, sessionId: string): Promise<void> {
    try {
      if (!GatewayClient.instance.isVoiceReady()) {
        throw new Error('连接尚未就绪，请连接后重试');
      }
      const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, perms);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        throw new Error('需要麦克风权限，请在系统设置中允许后重试');
      }
      if (this.cancelled) {
        return;
      }
      this.capturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      });
      if (this.cancelled || !GatewayClient.instance.isVoiceReady()) {
        await this.release();
        return;
      }
      GatewayClient.instance.asrStart(16000, sessionId);
      this.wireOpen = true;
      this.capturer.on('readData', (buf: ArrayBuffer) => {
        if (!this.cancelled) {
          GatewayClient.instance.sendBin(buf);
        }
      });
      await this.capturer.start();
      this.startedAt = Date.now();
      this.running = true;
    } catch (err) {
      if (this.wireOpen) {
        GatewayClient.instance.asrCancel();
        this.wireOpen = false;
      }
      await this.release();
      throw new Error('无法启动麦克风，请检查权限与连接');
    }
  }

  async stop(cancel: boolean = false): Promise<boolean> {
    if (cancel || this.starting !== null) {
      this.cancelled = true;
    }
    if (this.stopping) {
      return this.stopping;
    }
    this.stopping = this.finish();
    try {
      return await this.stopping;
    } finally {
      this.stopping = null;
    }
  }

  private async finish(): Promise<boolean> {
    if (this.starting) {
      try {
        await this.starting;
      } catch (_err) {
        return false;
      }
    }
    this.duration = this.running ? Date.now() - this.startedAt : 0;
    await this.release();
    // Recheck after native release: a page exit may have cancelled meanwhile.
    const send = this.wireOpen && !this.cancelled && this.duration >= 400 && GatewayClient.instance.isVoiceReady();
    if (this.wireOpen) {
      if (send) {
        GatewayClient.instance.asrEnd();
      } else {
        GatewayClient.instance.asrCancel();
      }
      this.wireOpen = false;
    }
    return send;
  }

  private async release(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = null;
    this.running = false;
    if (!capturer) {
      return;
    }
    try {
      await capturer.stop();
    } catch (_err) {
      // May still be prepared when permission/startup was cancelled.
    }
    try {
      await capturer.release();
    } catch (_err) {
      // Already released by the audio service.
    }
  }
}

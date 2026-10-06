import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

/** Holds the phone-to-computer connection only while a user-started turn is active. */
export class BackgroundConnectionTask {
  private static running: boolean = false;
  private static transition: Promise<void> = Promise.resolve();
  private static cancelListenerRegistered: boolean = false;

  private static readonly onCancelled = (_info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    BackgroundConnectionTask.running = false;
  };

  private static enqueue(action: () => Promise<void>): Promise<void> {
    const next = BackgroundConnectionTask.transition.then(action, action);
    BackgroundConnectionTask.transition = next.then((): void => {}, (): void => {});
    return next;
  }

  static start(context: common.Context | null): Promise<boolean> {
    if (!context) { return Promise.resolve(false); }
    let started = true;
    return BackgroundConnectionTask.enqueue(async (): Promise<void> => {
      if (BackgroundConnectionTask.running) { return; }
      try {
        if (!BackgroundConnectionTask.cancelListenerRegistered) {
          try {
            backgroundTaskManager.on('continuousTaskCancel', BackgroundConnectionTask.onCancelled);
            BackgroundConnectionTask.cancelListenerRegistered = true;
          } catch (_error) {
            // The active task can still be stopped when the ability returns to foreground.
          }
        }
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: 'ai.hermes.harmes', abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 840203,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        await backgroundTaskManager.startBackgroundRunning(
          context, backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION, agent
        );
        BackgroundConnectionTask.running = true;
      } catch (_error) {
        started = false;
      }
    }).then((): boolean => started);
  }

  static stop(context: common.Context | null): Promise<void> {
    if (!context) { return Promise.resolve(); }
    return BackgroundConnectionTask.enqueue(async (): Promise<void> => {
      if (!BackgroundConnectionTask.running) { return; }
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        BackgroundConnectionTask.running = false;
      } catch (_error) {
        // Keep the state so a later lifecycle transition can retry the stop.
      }
    });
  }
}

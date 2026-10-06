import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';

/** Local system-banner notifications for assistant replies received by this process. */
export class TaskReplyNotifications {
  private static permissionRequest: Promise<boolean> | null = null;

  static async isEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (_error) {
      return false;
    }
  }

  static async requestPermission(context: common.Context): Promise<boolean> {
    if (TaskReplyNotifications.permissionRequest) {
      return TaskReplyNotifications.permissionRequest;
    }
    const request = (async (): Promise<boolean> => {
      try {
        if (await notificationManager.isNotificationEnabled()) {
          return true;
        }
        await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
        return await notificationManager.isNotificationEnabled();
      } catch (_error) {
        return await notificationManager.isNotificationEnabled().catch((): boolean => false);
      }
    })();
    TaskReplyNotifications.permissionRequest = request;
    const enabled = await request;
    TaskReplyNotifications.permissionRequest = null;
    return enabled;
  }

  static async openSystemSettings(context: common.Context): Promise<boolean> {
    try {
      await notificationManager.openNotificationSettingsWithResult(context as common.UIAbilityContext);
    } catch (_error) {
      // The user can also manage this app's notifications from system settings.
    }
    return await TaskReplyNotifications.isEnabled();
  }

  static async publishReply(sessionId: string, sessionTitle: string, reply: string, seq: number): Promise<void> {
    if (!await TaskReplyNotifications.isEnabled()) {
      return;
    }
    const text = reply.replace(/[\r\n\t ]+/g, ' ').trim();
    if (!sessionId || !text) {
      return;
    }
    const id = TaskReplyNotifications.notificationId(sessionId, seq);
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'ai.hermes.harmes',
          abilityName: 'EntryAbility',
          parameters: { 'notification_session_id': sessionId }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: id,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await notificationManager.publish({
        id: id,
        appMessageId: `hermes-reply:${sessionId}:${seq}`,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: sessionTitle.length > 36 ? `${sessionTitle.slice(0, 36)}…` : sessionTitle,
            text: text.length > 120 ? `${text.slice(0, 120)}…` : text
          }
        },
        wantAgent: agent
      });
    } catch (_error) {
      // A notification failure must not interfere with delivering the Hermes reply.
    }
  }

  private static notificationId(sessionId: string, seq: number): number {
    const value = `${sessionId}:${seq}`;
    let hash = 2166136261;
    for (let i = 0; i < value.length; i++) {
      hash ^= value.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    const id = hash & 0x7fffffff;
    return id === 0 ? 1 : id;
  }
}

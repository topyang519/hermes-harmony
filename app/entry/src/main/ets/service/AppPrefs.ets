/**
 * Non-secret UI prefs (session sync mode, sidebar, voice defaults).
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Theme } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';

const STORE = 'hermes_harmony_prefs';
const MAX_PHONE_SESSIONS = 24;
const MAX_AGENT_CONTEXTS = 24;

export class AppPrefs {
  static themeMode: string = 'system';
  static reduceMotion: boolean = false;
  static syncAllSessions: boolean = false;
  static sidebarCollapsed: boolean = true;
  /** Preferred mode; voice is usable only while computer readiness is confirmed. */
  static voiceInputMode: boolean = false;
  /** Auto TTS after assistant message.complete */
  static autoVoiceReply: boolean = false;
  static initialSetupReminderShown: boolean = false;
  static phoneSessionIds: string[] = [];
  static agentSessions: Record<string, string> = {};

  static async load(ctx: common.Context): Promise<void> {
    try {
      const store = await preferences.getPreferences(ctx, STORE);
      const savedTheme = await store.get('theme_mode', 'system') as string;
      AppPrefs.themeMode = savedTheme === 'dark' || savedTheme === 'light' ? savedTheme : 'system';
      AppPrefs.reduceMotion = (await store.get('reduce_motion', false)) as boolean;
      AppPrefs.syncAllSessions = (await store.get('sync_all_sessions', false)) as boolean;
      AppPrefs.sidebarCollapsed = (await store.get('sidebar_collapsed', true)) as boolean;
      AppPrefs.voiceInputMode = (await store.get('voice_input_mode', false)) as boolean;
      AppPrefs.autoVoiceReply = (await store.get('auto_voice_reply', false)) as boolean;
      AppPrefs.initialSetupReminderShown = (await store.get('initial_setup_reminder_shown', false)) as boolean;
      const raw = (await store.get('phone_session_ids', '')) as string;
      const ids = raw.length > 0 ? raw.split(',').filter((s: string) => s.length > 0) : [];
      AppPrefs.phoneSessionIds = ids.length > MAX_PHONE_SESSIONS ? ids.slice(ids.length - MAX_PHONE_SESSIONS) : ids;
      AppPrefs.agentSessions = {};
      const rawAgentSessions = (await store.get('agent_context_sessions', '')) as string;
      if (rawAgentSessions.length > 0) {
        try {
          const saved = JSON.parse(rawAgentSessions) as Record<string, Object>;
          const keys = Object.keys(saved);
          const restored: Record<string, string> = {};
          const start = Math.max(0, keys.length - MAX_AGENT_CONTEXTS);
          for (let i = start; i < keys.length; i++) {
            const value = saved[keys[i]];
            if (typeof value === 'string') {
              restored[keys[i]] = value;
            }
          }
          AppPrefs.agentSessions = restored;
        } catch (_e) {
          AppPrefs.agentSessions = {};
        }
      }
    } catch (_e) {
      // first launch defaults
    }
    AppPrefs.publish();
  }

  static async save(ctx: common.Context): Promise<void> {
    try {
      const store = await preferences.getPreferences(ctx, STORE);
      await store.put('theme_mode', AppPrefs.themeMode);
      await store.put('reduce_motion', AppPrefs.reduceMotion);
      await store.put('sync_all_sessions', AppPrefs.syncAllSessions);
      await store.put('sidebar_collapsed', AppPrefs.sidebarCollapsed);
      await store.put('voice_input_mode', AppPrefs.voiceInputMode);
      await store.put('auto_voice_reply', AppPrefs.autoVoiceReply);
      await store.put('initial_setup_reminder_shown', AppPrefs.initialSetupReminderShown);
      await store.put('phone_session_ids', AppPrefs.phoneSessionIds.join(','));
      await store.put('agent_context_sessions', JSON.stringify(AppPrefs.agentSessions));
      await store.flush();
    } catch (_e) {
      // ignore
    }
    AppPrefs.publish();
  }

  static async claimInitialSetupReminder(ctx: common.Context): Promise<boolean> {
    if (AppPrefs.initialSetupReminderShown) {
      return false;
    }
    AppPrefs.initialSetupReminderShown = true;
    try {
      const store = await preferences.getPreferences(ctx, STORE);
      await store.put('initial_setup_reminder_shown', true);
      await store.flush();
    } catch (_e) {
      // Keep the reminder dismissed for this process if preferences are unavailable.
    }
    return true;
  }

  static publish(): void {
    AppMotion.manualReduced = AppPrefs.reduceMotion;
    Theme.update(AppPrefs.themeMode === 'system' ? Theme.systemMode : AppPrefs.themeMode);
    try {
      AppMotion.publish();
      AppStorage.setOrCreate('hermes_reduce_motion_preference', AppPrefs.reduceMotion);
      AppStorage.setOrCreate('hermes_theme', Theme.mode);
      AppStorage.setOrCreate('hermes_theme_preference', AppPrefs.themeMode);
      AppStorage.setOrCreate('hermes_sync_all', AppPrefs.syncAllSessions);
      AppStorage.setOrCreate('hermes_sidebar_collapsed', AppPrefs.sidebarCollapsed);
      AppStorage.setOrCreate('hermes_voice_mode', AppPrefs.voiceInputMode && AppStorage.get<boolean>('hermes_voice_ready') === true);
      AppStorage.setOrCreate('hermes_auto_voice', AppPrefs.autoVoiceReply && AppStorage.get<boolean>('hermes_voice_ready') === true);
    } catch (_e) {
      // AgentExtensionAbility has no UI surface to publish preferences into.
    }
  }

  static async setTheme(ctx: common.Context, mode: string): Promise<void> {
    AppPrefs.themeMode = mode === 'dark' || mode === 'light' ? mode : 'system';
    AppPrefs.publish();
    await AppPrefs.save(ctx);
  }

  static async setReduceMotion(ctx: common.Context, reduced: boolean): Promise<void> {
    AppPrefs.reduceMotion = reduced;
    AppPrefs.publish();
    await AppPrefs.save(ctx);
  }

  static updateSystemTheme(mode: string): void {
    Theme.systemMode = mode === 'dark' ? 'dark' : 'light';
    if (AppPrefs.themeMode === 'system') {
      AppPrefs.publish();
    }
  }

  static isPhoneOwned(sessionId: string): boolean {
    if (!sessionId) {
      return false;
    }
    return AppPrefs.phoneSessionIds.indexOf(sessionId) >= 0;
  }

  static async rememberPhoneSession(ctx: common.Context | null, sessionId: string): Promise<void> {
    if (!sessionId || AppPrefs.isPhoneOwned(sessionId)) {
      return;
    }
    const next = AppPrefs.phoneSessionIds.concat([sessionId]);
    AppPrefs.phoneSessionIds = next.length > MAX_PHONE_SESSIONS ? next.slice(next.length - MAX_PHONE_SESSIONS) : next;
    if (ctx) {
      await AppPrefs.save(ctx);
    } else {
      AppPrefs.publish();
    }
  }

  static async forgetPhoneSession(ctx: common.Context | null, sessionId: string): Promise<void> {
    await AppPrefs.forgetPhoneSessions(ctx, [sessionId]);
  }

  static async forgetPhoneSessions(ctx: common.Context | null, sessionIds: string[]): Promise<void> {
    const ids = sessionIds.filter((sid: string) => sid.length > 0);
    if (ids.length === 0) {
      return;
    }
    AppPrefs.phoneSessionIds = AppPrefs.phoneSessionIds.filter((sid: string) => ids.indexOf(sid) < 0);
    if (ctx) {
      await AppPrefs.save(ctx);
    } else {
      AppPrefs.publish();
    }
  }

  static async forgetAgentSessionsForSessions(ctx: common.Context | null, sessionIds: string[]): Promise<void> {
    const ids = sessionIds.filter((sid: string) => sid.length > 0);
    if (ids.length === 0) { return; }
    const next: Record<string, string> = {};
    const keys = Object.keys(AppPrefs.agentSessions);
    let changed = false;
    for (let i = 0; i < keys.length; i++) {
      const contextId = keys[i];
      if (ids.indexOf(AppPrefs.agentSessions[contextId]) >= 0) {
        changed = true;
      } else {
        next[contextId] = AppPrefs.agentSessions[contextId];
      }
    }
    if (!changed) { return; }
    AppPrefs.agentSessions = next;
    if (ctx) { await AppPrefs.save(ctx); }
    else { AppPrefs.publish(); }
  }

  static async rememberAgentSession(ctx: common.Context | null, contextId: string, sessionId: string): Promise<void> {
    if (!contextId || !sessionId) { return; }
    const next: Record<string, string> = {};
    const keys = Object.keys(AppPrefs.agentSessions);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== contextId) {
        next[keys[i]] = AppPrefs.agentSessions[keys[i]];
      }
    }
    next[contextId] = sessionId;
    const nextKeys = Object.keys(next);
    const start = Math.max(0, nextKeys.length - MAX_AGENT_CONTEXTS);
    const bounded: Record<string, string> = {};
    for (let i = start; i < nextKeys.length; i++) {
      bounded[nextKeys[i]] = next[nextKeys[i]];
    }
    AppPrefs.agentSessions = bounded;
    if (ctx) { await AppPrefs.save(ctx); }
    else { AppPrefs.publish(); }
  }

  static async forgetAgentSession(ctx: common.Context | null, contextId: string): Promise<void> {
    if (!contextId || AppPrefs.agentSessions[contextId] === undefined) { return; }
    const next: Record<string, string> = {};
    const keys = Object.keys(AppPrefs.agentSessions);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== contextId) {
        next[keys[i]] = AppPrefs.agentSessions[keys[i]];
      }
    }
    AppPrefs.agentSessions = next;
    if (ctx) { await AppPrefs.save(ctx); }
    else { AppPrefs.publish(); }
  }
}

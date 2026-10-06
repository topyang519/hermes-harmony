import { AgentExtensionAbility, Want, common } from '@kit.AbilityKit';
import { createA2AServer, RequestContext, Server, TaskState } from '@kit.AgentFrameworkKit';
import { GatewayClient } from '../service/GatewayClient';

/** Xiaoyi端A2A入口。所有命令继续复用用户在App中配置的电脑网关。 */
export default class HermesAgentAbility extends AgentExtensionAbility {
  private server: Server | null = null;
  private cancelledTasks: Set<string> = new Set<string>();

  onCreate(want: Want): void {
    GatewayClient.instance.attachContext(this.context);
    try {
      this.server = createA2AServer(this.context.agentCard,
        (method: string, request: RequestContext): void => {
          void this.handleRequest(method, request);
        }, want);
      this.server.start();
    } catch (_error) {
      this.server = null;
    }
  }

  onData(proxy: common.AgentHostProxy, data: string): void {
    if (!this.server) { return; }
    this.server.onMessage(data, (response: string): void => {
      try {
        proxy.sendData(response);
      } catch (_error) {
        // The system client may disconnect while a task is completing.
      }
    });
  }

  onAuth(proxy: common.AgentHostProxy, handshakeData: string): void {
    if (!this.server) { return; }
    try {
      proxy.authorize(this.server.onAuth(handshakeData));
    } catch (_error) {
      // Authentication failures are returned through the system A2A channel.
    }
  }

  onDestroy(): void {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
  }

  private async handleRequest(method: string, request: RequestContext): Promise<void> {
    const taskId = request.getTaskId() ?? '';
    const server = this.server;
    if (!taskId || !server) { return; }

    if (method === 'Execute') {
      await this.execute(taskId, request);
      return;
    }
    if (method === 'Cancel') {
      this.cancelledTasks.add(taskId);
      const confirmed = await GatewayClient.instance.cancelAgentTask(taskId);
      if (confirmed) {
        server.updateStatus(taskId, { state: TaskState.CANCELED });
      } else {
        server.addArtifact(taskId, {
          name: '未确认远端中断',
          parts: [{ text: '手机未能确认电脑上的 Hermes 已停止。请在电脑端检查任务状态后再继续。' }],
          lastChunk: true
        });
        server.updateStatus(taskId, { state: TaskState.FAILED });
      }
      return;
    }
    if (method === 'ClearContext') {
      GatewayClient.instance.clearAgentContext(request.getContextId() ?? '');
      server.addArtifact(taskId, {
        name: 'Hermes 会话', parts: [{ text: '已清除当前小艺对话关联。' }], lastChunk: true
      });
      server.updateStatus(taskId, { state: TaskState.COMPLETED });
      return;
    }
    if (method === 'PerceptionSuggest') {
      server.addArtifact(taskId, {
        name: '建议指令',
        parts: [{ text: '查看电脑上 Hermes 的状态；总结当前项目；让 Hermes 在当前项目中修复一个问题。' }],
        lastChunk: true
      });
      server.updateStatus(taskId, { state: TaskState.COMPLETED });
      return;
    }
    server.addArtifact(taskId, {
      name: 'Hermes Agent', parts: [{ text: `暂不支持的小艺请求：${method}` }], lastChunk: true
    });
    server.updateStatus(taskId, { state: TaskState.FAILED });
  }

  private async execute(taskId: string, request: RequestContext): Promise<void> {
    const server = this.server;
    if (!server) { return; }
    if (this.cancelledTasks.has(taskId) || GatewayClient.instance.isAgentTaskCancelled(taskId)) {
      server.updateStatus(taskId, { state: TaskState.CANCELED });
      this.cancelledTasks.delete(taskId);
      GatewayClient.instance.finishAgentTask(taskId);
      return;
    }
    server.updateStatus(taskId, { state: TaskState.WORKING });
    let hasProgressArtifact = false;
    const appendArtifact = (name: string, text: string, lastChunk: boolean): void => {
      try {
        server.addArtifact(taskId, {
          artifactId: taskId,
          name: name,
          parts: [{ text: text, mediaType: 'text/plain' }],
          append: hasProgressArtifact,
          lastChunk: lastChunk
        });
        hasProgressArtifact = true;
      } catch (_error) {
        // A progress card must not interrupt an active Hermes request.
      }
    };
    try {
      const userInput = request.getUserInput().trim();
      if (!userInput) {
        throw new Error('没有收到小艺提供的任务文本');
      }
      const result = await GatewayClient.instance.runAgentCommand(
        taskId, request.getContextId() ?? taskId, userInput, (notice): void => {
          if (this.cancelledTasks.has(taskId) || GatewayClient.instance.isAgentTaskCancelled(taskId)) {
            return;
          }
          if (notice.kind === 'approval') {
            appendArtifact('Hermes 正在等待确认',
              '电脑上的 Hermes 正在等待一项操作审批。请在赫默狮的这条对话中查看详情并明确批准或拒绝；处理后本次小艺任务会继续并返回结果。',
              false);
          } else {
            const detail = notice.text ? `\n${notice.text}` : '';
            appendArtifact('Hermes 需要补充信息',
              `电脑上的 Hermes 需要补充信息。请在赫默狮的这条对话中回答；之后本次小艺任务会继续并返回结果。${detail}`,
              false);
          }
        }
      );
      if (this.cancelledTasks.has(taskId) || GatewayClient.instance.isAgentTaskCancelled(taskId)) {
        return;
      }
      appendArtifact(hasProgressArtifact ? 'Hermes 执行状态与结果' : 'Hermes 回复', result.text, true);
      server.updateStatus(taskId, { state: TaskState.COMPLETED });
    } catch (error) {
      if (this.cancelledTasks.has(taskId) || GatewayClient.instance.isAgentTaskCancelled(taskId)) {
        return;
      }
      const message = error instanceof Error ? error.message : `${error}`;
      appendArtifact(hasProgressArtifact ? 'Hermes 执行状态与错误' : 'Hermes 执行失败', message, true);
      server.updateStatus(taskId, { state: TaskState.FAILED });
    } finally {
      this.cancelledTasks.delete(taskId);
      GatewayClient.instance.finishAgentTask(taskId);
    }
  }
}

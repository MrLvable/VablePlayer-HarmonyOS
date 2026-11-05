import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 推送通知 —— 用系统 notificationManager
 *
 * 用途：
 *  · 下载完成提醒
 *  · 订阅内容更新提醒
 *  · 新片上线提醒
 */
export class Push {
  private static readonly NOTIFY_ID_BASE: number = 1000;
  private static nextId: number = 1000;

  /** 请求通知授权 */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      return false;
    }
  }

  /** 发通知 */
  static async send(title: string, text: string, extra?: string): Promise<void> {
    try {
      Push.nextId = Push.nextId + 1;
      const req: notificationManager.NotificationRequest = {
        id: Push.nextId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: extra !== undefined ? extra : ''
          }
        }
      };
      await notificationManager.publish(req);
    } catch (e) {
      // 通知失败不影响主流程
    }
  }

  /** 下载完成通知 */
  static async notifyDownloadDone(title: string): Promise<void> {
    await Push.send('下载完成', title + ' 已保存到本地');
  }

  /** 订阅更新通知 */
  static async notifyNewContent(count: number): Promise<void> {
    await Push.send('订阅更新', '有 ' + count.toString() + ' 个新内容上线');
  }

  /** 清空所有通知 */
  static async clearAll(): Promise<void> {
    try {
      await notificationManager.cancelAll();
    } catch (e) {
      // 忽略
    }
  }
}

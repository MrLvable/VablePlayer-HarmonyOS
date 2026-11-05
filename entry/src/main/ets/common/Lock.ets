import { userAuth } from '@kit.UserAuthenticationKit';
import { common } from '@kit.AbilityKit';

/**
 * 应用锁 —— PIN 码 + 生物识别（指纹 / 人脸 / 锁屏密码）
 */
export class Lock {
  /** 简单哈希（双 djb2 + 盐），足够媒体应用使用 */
  static hash(pin: string): string {
    const salt = 'nasplayer_salt_v1';
    const s = salt + pin + salt;
    let h = 5381;
    for (let i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.charCodeAt(i)) & 0x7FFFFFFF;
    }
    let h2 = 52711;
    for (let i = s.length - 1; i >= 0; i--) {
      h2 = ((h2 << 5) + h2 + s.charCodeAt(i)) & 0x7FFFFFFF;
    }
    return h.toString(16) + '-' + h2.toString(16);
  }

  /** 调起系统生物识别；不可用时返回 false */
  static async authenticate(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const authParam: userAuth.AuthParam = {
        challenge: new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
        authType: [
          userAuth.UserAuthType.FINGERPRINT,
          userAuth.UserAuthType.FACE,
          userAuth.UserAuthType.PIN
        ],
        authTrustLevel: userAuth.AuthTrustLevel.ATL3
      };
      const widgetParam: userAuth.WidgetParam = {
        title: '解锁 VablePlayer'
      };
      const inst = userAuth.getUserAuthInstance(authParam, widgetParam);
      userAuth.getUserAuthInstance(authParam, widgetParam);

      return await new Promise<boolean>((resolve) => {
        try {
          inst.on('result', {
            onResult: (r: userAuth.UserAuthResult) => {
              resolve(r.result === userAuth.UserAuthResultCode.SUCCESS);
            }
          });
          inst.start();
        } catch (e) {
          resolve(false);
        }
      });
    } catch (e) {
      return false;
    }
  }
}

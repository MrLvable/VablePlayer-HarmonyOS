import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 桌面小组件 —— 「继续播放」卡片
 *
 * 对应 HosPlayer 的 EntryResumeFormAbility
 * 从 preferences 读最近播放的内容，展示在桌面
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const data: Record<string, string> = {
      'title': 'VablePlayer',
      'subtitle': '打开应用继续观看',
      'image': '',
      'progress': '0'
    };
    // 尝试读上次播放
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: 'nas_player' });
      const t = pref.getSync('last_title', '') as string;
      const st = pref.getSync('last_subtitle', '') as string;
      const img = pref.getSync('last_image', '') as string;
      const pg = pref.getSync('last_progress', '0') as string;
      if (t.length > 0) {
        data['title'] = t;
        data['subtitle'] = st.length > 0 ? st : '继续观看';
        data['image'] = img;
        data['progress'] = pg;
      }
    } catch (e) {
      // 用默认值
    }
    return formBindingData.createFormBindingData(data);
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    const data: Record<string, string> = {
      'title': 'VablePlayer',
      'subtitle': '打开应用继续观看',
      'image': '',
      'progress': '0'
    };
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: 'nas_player' });
      const t = pref.getSync('last_title', '') as string;
      if (t.length > 0) {
        data['title'] = t;
        data['subtitle'] = pref.getSync('last_subtitle', '') as string;
        data['image'] = pref.getSync('last_image', '') as string;
        data['progress'] = pref.getSync('last_progress', '0') as string;
      }
    } catch (e) {
      // 忽略
    }
    formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  }

  onFormEvent(formId: string, message: string): void {
    // 点击卡片 → 由卡片自己 router 跳转
  }

  onRemoveForm(formId: string): void {
  }
}

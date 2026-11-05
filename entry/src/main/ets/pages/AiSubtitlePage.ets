import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { AiSubtitleSettings } from '../components/AiSubtitleSettings';
import { AiSubtitleWorkbench } from '../components/AiSubtitleWorkbench';

@Entry
@Component
struct AiSubtitlePage {
  @State private showWorkbench: boolean = false;

  onBackPress(): boolean {
    if (this.showWorkbench) { this.showWorkbench = false; return true; }
    return false;
  }

  build() {
    Stack() {
      if (this.showWorkbench) {
        AiSubtitleWorkbench({ dark: Theme.isDark(), fullScreenOverlay: true,
          onClose: () => { this.showWorkbench = false; },
          onConfigure: () => { this.showWorkbench = false; }
        })
      } else {
        AiSubtitleSettings({ dark: Theme.isDark(), fullScreenOverlay: true, onClose: () => { router.back(); },
          onSaved: () => {}, onOpenTool: () => { this.showWorkbench = true; }
        })
      }
    }.width('100%').height('100%')
  }
}

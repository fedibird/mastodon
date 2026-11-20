import { readFileSync } from 'fs';
import path from 'path';

// The privacy portal contains the WebUI HotKeys wrapper and react-overlays
// dropdown portals as siblings. Only the former should inherit app layout.
const sourceRoot = path.resolve(__dirname, '../../../');
const readSource = filename => readFileSync(path.join(sourceRoot, filename), 'utf8');

describe('dropdown privacy portal layout selectors', () => {
  it('does not apply the WebUI flex/viewport sizing to overlay siblings', () => {
    const portal = document.createElement('div');
    portal.className = 'emoji-mutes-privacy-portal';

    const webui = document.createElement('div');
    webui.className = 'emoji-mutes-webui-hotkeys';
    const overlay = document.createElement('div');
    const emojiActionsOverlay = document.createElement('div');
    emojiActionsOverlay.id = 'emoji-actions-overlay-root';
    portal.append(webui, overlay, emojiActionsOverlay);

    ['styles/mastodon/basics.scss', 'styles/mastodon/components.scss'].forEach(filename => {
      const source = readSource(filename);
      const selectors = [...source.matchAll(/\.emoji-mutes-privacy-portal\s*>\s*([^\s,{]+)/g)]
        .map(match => `.emoji-mutes-privacy-portal > ${match[1]}`);

      expect(selectors.length).toBeGreaterThan(0);
      selectors.forEach(selector => {
        expect([...portal.querySelectorAll(selector)]).toEqual([webui]);
        expect(overlay.matches(selector)).toBe(false);
        expect(emojiActionsOverlay.matches(selector)).toBe(false);
      });
    });
  });

  it('marks the actual react-hotkeys DOM wrapper for the scoped layout', () => {
    expect(readSource('mastodon/features/ui/index.js')).toContain(
      "<HotKeys className='emoji-mutes-webui-hotkeys'",
    );
  });
});

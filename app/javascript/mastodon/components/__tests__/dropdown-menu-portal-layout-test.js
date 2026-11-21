import { readFileSync } from 'fs';
import path from 'path';

// The privacy portal contains both the WebUI HotKeys wrapper and react-overlays
// dropdowns as direct children. The layout rules must only target HotKeys.
const sourceRoot = path.resolve(__dirname, '../../../');
const readSource = filename => readFileSync(path.join(sourceRoot, filename), 'utf8');

describe('dropdown privacy portal layout selectors', () => {
  it('scopes all privacy portal child layout selectors to the WebUI wrapper', () => {
    ['styles/mastodon/basics.scss', 'styles/mastodon/components.scss'].forEach(filename => {
      const source = readSource(filename);
      const childSelectors = [...source.matchAll(/\.emoji-mutes-privacy-portal\s*>\s*([^\s,{]+)/g)]
        .map(match => match[1]);

      // A broad "div" selector would resize the react-overlays popper portal,
      // making menus appear centered instead of next to their trigger.
      expect(childSelectors.length).toBeGreaterThan(0);
      childSelectors.forEach(selector => {
        expect(selector).toBe('.emoji-mutes-webui-hotkeys');
      });
    });
  });

  it('marks the actual react-hotkeys DOM wrapper for the scoped layout', () => {
    expect(readSource('mastodon/features/ui/index.js')).toMatch(
      /<HotKeys className='emoji-mutes-webui-hotkeys'/,
    );
  });
});

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
      const portalChildSelector = '.emoji-mutes-privacy-portal >';
      const expectedSelector = '.emoji-mutes-privacy-portal > .emoji-mutes-webui-hotkeys';
      const selectorLines = source.split('\n')
        .map(line => line.trim())
        .filter(line => line.includes(portalChildSelector) && !line.startsWith('//'));

      // A broad "div" selector would resize the react-overlays popper portal,
      // making menus appear centered instead of next to their trigger.
      expect(selectorLines.length).toBeGreaterThan(0);
      selectorLines.forEach(line => {
        expect(line).toContain(expectedSelector);
      });
    });
  });

  it('marks the actual react-hotkeys DOM wrapper for the scoped layout', () => {
    expect(readSource('mastodon/features/ui/index.js')).toMatch(
      /<HotKeys className='emoji-mutes-webui-hotkeys'/,
    );
  });
});

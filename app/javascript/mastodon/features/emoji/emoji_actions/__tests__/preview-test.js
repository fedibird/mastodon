import { buildEmojiActionsPreview, positionEmojiActionsPreview } from '../preview';

describe('emoji actions preview', () => {
  it('places optional name and shortcode underneath a custom image', () => {
    const reference = { kind: 'custom', scope: 'local', custom_emoji_id: '42', shortcode: 'wide' };
    expect(buildEmojiActionsPreview(reference, {
      reference,
      detail: { emoji: { shortcode: 'wide', static_url: '/wide.png', alternate_name: 'Long wide emoji' } },
    }, null)).toEqual({
      native: null, imageSrc: '/wide.png', name: 'Long wide emoji', shortcode: ':wide:',
    });

    const remote = { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'wide' };
    expect(buildEmojiActionsPreview(remote, { detail: { emoji: { url: '/remote.png' } } }, null).shortcode).toBe(':wide@other.example:');
  });

  it('renders unicode and omits unknown shortcode rather than inventing one', () => {
    const preview = buildEmojiActionsPreview({ kind: 'unicode', native: '😀' }, {
      detail: { label: 'にっこり', image: { src: '/smile.svg' } },
    }, null);
    expect(preview.imageSrc).toBe('/smile.svg');
    expect(preview.name).toBe('にっこり');
    expect(preview.shortcode === null || /^:.+:$/.test(preview.shortcode)).toBe(true);
  });

  it('uses only an existing rendered image if an uncached remote reference cannot resolve', () => {
    const reference = { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'unknown' };
    expect(buildEmojiActionsPreview(reference, { detail: { state: 'unfetched' } }, null)).toBeNull();
  });

  it('never shifts menu item coordinates when there is room above', () => {
    const menu = { left: 100, right: 300, top: 340, bottom: 620, width: 200, height: 280 };
    expect(positionEmojiActionsPreview(menu, { width: 300, height: 220 }, { width: 900, height: 800 })).toEqual({
      left: -50, top: -228,
    });
  });

  it('chooses a side near the top edge, and a space above at the bottom edge', () => {
    const top = { left: 16, right: 220, top: 12, bottom: 370, width: 204, height: 358 };
    expect(positionEmojiActionsPreview(top, { width: 300, height: 220 }, { width: 900, height: 800 })).toEqual({
      left: 212, top: 0,
    });
    const bottom = { left: 16, right: 220, top: 420, bottom: 778, width: 204, height: 358 };
    expect(positionEmojiActionsPreview(bottom, { width: 300, height: 220 }, { width: 900, height: 800 }).top).toBe(-228);
  });

  it('rejects an oversized preview instead of introducing page overflow', () => {
    const menu = { left: 8, right: 200, top: 50, bottom: 320, width: 192, height: 270 };
    expect(positionEmojiActionsPreview(menu, { width: 400, height: 170 }, { width: 320, height: 650 })).toBeNull();
    expect(positionEmojiActionsPreview(menu, { width: 280, height: 700 }, { width: 320, height: 650 })).toBeNull();
  });
  it('omits preview if a narrow viewport cannot fit both without obscuring actions', () => {
    const menu = { left: 10, right: 280, top: 80, bottom: 510, width: 270, height: 430 };
    expect(positionEmojiActionsPreview(menu, { width: 300, height: 220 }, { width: 320, height: 560 })).toBeNull();
  });
});

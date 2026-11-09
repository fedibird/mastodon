import { buildEmojiActionMenuItems } from '../emoji_actions_menu_controller';

const intl = {
  formatMessage: (message, values = {}) => {
    let text = message.defaultMessage || message.id;
    Object.keys(values).forEach(key => {
      text = text.replace(`{${key}}`, values[key]);
    });
    return text;
  },
};

describe('buildEmojiActionMenuItems', () => {
  const reference = { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' };

  it('disables mutating actions when resolve did not return actions', () => {
    const onRetry = jest.fn();
    const items = buildEmojiActionMenuItems({
      intl,
      reference,
      resolved: null,
      mute: null,
      categories: [{ id: 'favorites', name: 'Favorites', items: [] }],
      status: 'ready',
      error: new Error('offline'),
      busy: false,
      onMute: jest.fn(),
      onUnmute: jest.fn(),
      onAddToCategory: jest.fn(),
      onRetry,
    });

    expect(items.some(item => item && item.text === 'Mute emoji')).toBe(false);
    expect(items.some(item => item && item.text === 'Add to Favorites')).toBe(false);
    expect(items.some(item => item && item.text === 'Try again' && item.action === onRetry)).toBe(true);
    expect(items.some(item => item && item.to && item.to.includes('emoji_detail'))).toBe(true);
  });

  it('shows category append only when resolve allows it', () => {
    const onAdd = jest.fn();
    const items = buildEmojiActionMenuItems({
      intl,
      reference: { kind: 'unicode', native: '😀' },
      resolved: {
        reference: { kind: 'unicode', native: '😀' },
        actions: {
          add_to_personal_category: { allowed: true },
          mute: { allowed: true },
        },
      },
      mute: null,
      categories: [{ id: 'favorites', name: 'Favorites', items: [] }],
      status: 'ready',
      error: null,
      busy: false,
      onMute: jest.fn(),
      onUnmute: jest.fn(),
      onAddToCategory: onAdd,
      onRetry: jest.fn(),
    });

    expect(items.some(item => item && item.text === 'Mute emoji')).toBe(true);
    expect(items.some(item => item && item.text === 'Add to Favorites')).toBe(true);
  });

  it('hides category append for remote emoji when resolve denies it', () => {
    const items = buildEmojiActionMenuItems({
      intl,
      reference,
      resolved: {
        reference,
        actions: {
          add_to_personal_category: { allowed: false, reason: 'remote_emoji' },
          mute: { allowed: true },
        },
      },
      mute: null,
      categories: [{ id: 'favorites', name: 'Favorites', items: [] }],
      status: 'ready',
      error: null,
      busy: false,
      onMute: jest.fn(),
      onUnmute: jest.fn(),
      onAddToCategory: jest.fn(),
      onRetry: jest.fn(),
    });

    expect(items.some(item => item && item.text === 'Mute emoji')).toBe(true);
    expect(items.some(item => item && item.text === 'Add to Favorites')).toBe(false);
  });

  it('keeps the saved mute and offers sync retry after sync-only failure', () => {
    const onRetrySync = jest.fn();
    const onMute = jest.fn();
    const items = buildEmojiActionMenuItems({
      intl,
      reference: { kind: 'unicode', native: '😀' },
      resolved: {
        reference: { kind: 'unicode', native: '😀' },
        actions: { mute: { allowed: true }, add_to_personal_category: { allowed: true } },
      },
      mute: { id: '10', revision: '4', emoji: { kind: 'unicode', native: '😀' } },
      categories: [],
      status: 'ready',
      error: null,
      syncError: Object.assign(new Error('offline'), { status: 503 }),
      pendingSyncRevision: '4',
      busy: false,
      onMute,
      onUnmute: jest.fn(),
      onAddToCategory: jest.fn(),
      onRetry: jest.fn(),
      onRetrySync,
    });

    expect(items.some(item => item && item.text === 'Muted')).toBe(true);
    expect(items.some(item => item && item.text === 'Refresh mute list' && item.action === onRetrySync)).toBe(true);
    const unmute = items.find(item => item && item.text === 'Unmute emoji');
    expect(unmute.disabled).toBe(true);
    expect(items.some(item => item && item.text === 'Mute emoji')).toBe(false);
  });
});

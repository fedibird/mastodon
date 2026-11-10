import { openEmojiActions, setEmojiActionsListener, resetEmojiActionsBusForTests } from '../emoji_actions/bus';

describe('openEmojiActions', () => {
  afterEach(() => {
    resetEmojiActionsBusForTests();
  });

  it('delivers a normalized reference to the registered listener', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);

    expect(openEmojiActions({ kind: 'unicode', native: '😀' }, { source: 'test', status_id: '1' })).toBe(true);
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      reference: { kind: 'unicode', native: '😀' },
      source: 'test',
      status_id: '1',
    }));
  });

  it('rejects an incomplete reference', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);

    expect(openEmojiActions({ kind: 'custom', scope: 'remote', shortcode: 'blob' })).toBe(false);
    expect(listener).not.toHaveBeenCalled();
  });
});

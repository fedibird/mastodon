const documentFor = revision => ({
  revision,
  emoji_mutes: [
    {
      id: '1',
      revision: 1,
      emoji: { kind: 'unicode', native: '👍' },
      effects: { hide_reactions: true, replace_in_text: true, reject_reactions_to_own_posts: true, hide_in_picker: true },
      replacement: '［絵文字］',
      availability: 'available',
    },
  ],
});

describe('emoji mute store', () => {
  let store;
  let get;

  beforeEach(() => {
    jest.resetModules();
    get = jest.fn(() => Promise.resolve({ data: documentFor(2) }));
    jest.doMock('mastodon/api', () => ({ __esModule: true, default: () => ({ get }) }));
    jest.doMock('mastodon/initial_state_data', () => ({
      __esModule: true,
      default: { meta: { access_token: 'test-token', me: 'account-1' } },
    }));
    store = require('../emoji_mute_store');
    jest.spyOn(Storage.prototype, 'setItem');
    jest.spyOn(Storage.prototype, 'getItem');
  });

  afterEach(() => {
    localStorage.clear();
    jest.dontMock('mastodon/api');
    jest.dontMock('mastodon/initial_state_data');
    jest.restoreAllMocks();
  });

  it('keeps the document in memory and ignores an older response', async () => {
    await store.loadEmojiMutes();
    expect(store.currentEmojiMuteRevision()).toBe(2);
    expect(store.currentEmojiMutes()[0].emoji.native).toBe('👍');
    expect(localStorage.setItem).not.toHaveBeenCalled();
    expect(localStorage.getItem).not.toHaveBeenCalled();

    await store.noteEmojiMutesChanged({ revision: 1 });
    expect(store.currentEmojiMuteRevision()).toBe(2);
    expect(get).toHaveBeenCalledTimes(1);

    get.mockImplementationOnce(() => Promise.resolve({ data: documentFor(3) }));
    await store.noteEmojiMutesChanged({ revision: 4 });
    expect(store.currentEmojiMuteRevision()).toBe(2);

    get.mockImplementationOnce(() => Promise.resolve({ data: documentFor(4) }));
    await store.noteEmojiMutesChanged({ revision: 4 });
    expect(store.currentEmojiMuteRevision()).toBe(4);
  });

  it('keeps the previous reaction snapshot when the status revision is older', async () => {
    await store.loadEmojiMutes();
    const status = {
      id: '9',
      emoji_mutes_revision: 1,
      emoji_reactions: [{ name: '👍', count: 1 }],
      emoji_reactions_count: 1,
    };
    const previous = {
      get(key) {
        if (key === 'emoji_reactions') {
          return { toJS: () => [{ name: '🔥', count: 2, account_ids: ['1'] }] };
        }
        if (key === 'emoji_reactions_count') {
          return 2;
        }
        return null;
      },
    };

    store.keepFreshReactions(status, previous);
    expect(status.emoji_mutes_revision).toBeUndefined();
    expect(status.emoji_reactions).toEqual([{ name: '🔥', count: 2, account_ids: ['1'] }]);
    expect(status.emoji_reactions_count).toBe(2);
  });
});

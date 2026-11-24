jest.mock('mastodon/initial_state_data', () => ({
  __esModule: true,
  default: { meta: { me: 'account-1' } },
}));

const STORAGE_KEY = 'fedibird:emoji-mute-boot-bypass';

const loadModule = () => {
  jest.resetModules();
  return require('../emoji_mute_boot_bypass');
};

describe('emoji mute boot bypass', () => {
  beforeEach(() => {
    sessionStorage.clear();
    window.history.replaceState({}, '', '/web');
  });

  afterEach(() => {
    sessionStorage.clear();
    window.history.replaceState({}, '', '/');
  });

  it('does not skip WebUI mute loading, including a stored incident opt-in', () => {
    const initial = loadModule();
    expect(initial.TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING).toBe(false);
    expect(initial.emojiMuteBypassEnabled()).toBe(false);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();

    expect(initial.requestEmojiMuteBypass()).toBe(true);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBe('account-1');
    expect(initial.emojiMuteBypassEnabled()).toBe(false);
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);

    expect(initial.clearEmojiMuteBypass()).toBe(true);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
  });

  it('does not bypass another account or a non-WebUI page', () => {
    sessionStorage.setItem(STORAGE_KEY, 'account-2');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);

    sessionStorage.setItem(STORAGE_KEY, 'account-1');
    window.history.replaceState({}, '', '/settings');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
    window.history.replaceState({}, '', '/web/notifications');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
  });
});

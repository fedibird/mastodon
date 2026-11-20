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

  it('temporarily bypasses WebUI loading without an opt-in or stored preference', () => {
    const initial = loadModule();
    expect(initial.TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING).toBe(true);
    expect(initial.emojiMuteBypassEnabled()).toBe(true);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();

    expect(initial.requestEmojiMuteBypass()).toBe(true);
    expect(initial.emojiMuteBypassEnabled()).toBe(true);
    expect(loadModule().emojiMuteBypassEnabled()).toBe(true);
    expect(initial.clearEmojiMuteBypass()).toBe(true);
    expect(loadModule().emojiMuteBypassEnabled()).toBe(true);
  });

  it('discards a bypass for another account and does not bypass non-WebUI pages', () => {
    sessionStorage.setItem(STORAGE_KEY, 'account-2');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(true);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();

    sessionStorage.setItem(STORAGE_KEY, 'account-1');
    window.history.replaceState({}, '', '/settings');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
    window.history.replaceState({}, '', '/web/notifications');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(true);
  });
});

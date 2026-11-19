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

  it('is opt-in, tab-scoped, and takes effect only after a reload', () => {
    const initial = loadModule();
    expect(initial.emojiMuteBypassEnabled()).toBe(false);
    expect(initial.requestEmojiMuteBypass()).toBe(true);
    expect(initial.emojiMuteBypassEnabled()).toBe(false);

    const reloaded = loadModule();
    expect(reloaded.emojiMuteBypassEnabled()).toBe(true);
    expect(reloaded.clearEmojiMuteBypass()).toBe(true);
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
  });

  it('rejects an earlier account and does not apply on non-WebUI pages', () => {
    sessionStorage.setItem(STORAGE_KEY, 'account-2');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
    expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();

    sessionStorage.setItem(STORAGE_KEY, 'account-1');
    window.history.replaceState({}, '', '/settings');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(false);
    window.history.replaceState({}, '', '/web');
    expect(loadModule().emojiMuteBypassEnabled()).toBe(true);
  });
});

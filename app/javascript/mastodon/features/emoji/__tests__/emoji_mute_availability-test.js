import {
  currentEmojiMuteBoot,
  emojiMuteBootFromMeta,
  emojiMuteConfirmation,
  noteEmojiMuteDisabledLocally,
  noteEmojiMuteEnabledLocally,
  resetEmojiMuteBootForTests,
} from '../emoji_mute_availability';

describe('emoji mute availability', () => {
  afterEach(() => {
    resetEmojiMuteBootForTests();
  });

  it('treats a missing flag as unknown rather than off', () => {
    const boot = emojiMuteBootFromMeta({ me: '1', access_token: 'token' });

    expect(boot.availability).toBe('unknown');
    expect(boot.fetch).toBe(true);
    expect(boot.display).toBe('suppress');
    expect(boot.modal).toBe(false);
  });

  it('skips the boot fetch only for a known false', () => {
    const off = emojiMuteBootFromMeta({
      me: '1',
      emoji_mute_enabled_known: true,
      emoji_mute_enabled: false,
      emoji_mute_enabled_explicit: false,
      emoji_mute_modal: true,
    });

    expect(off).toMatchObject({ availability: 'disabled', explicit: false, fetch: false, display: 'show', modal: true });

    const explicit = emojiMuteBootFromMeta({
      me: '1',
      emoji_mute_enabled_known: true,
      emoji_mute_enabled: false,
      emoji_mute_enabled_explicit: true,
    });

    expect(explicit.explicit).toBe(true);
    expect(explicit.fetch).toBe(false);
  });

  it('fetches when the feature is on and confirms only when the serializer asked', () => {
    const on = emojiMuteBootFromMeta({
      me: '1',
      emoji_mute_enabled_known: true,
      emoji_mute_enabled: true,
      emoji_mute_modal: true,
    });

    expect(on).toMatchObject({ availability: 'enabled', fetch: true, display: 'suppress', modal: true });
    expect(emojiMuteConfirmation({ boot: on, operation: 'mute' })).toEqual({
      required: true,
      reenable: false,
      reason: 'mute',
    });
    expect(emojiMuteConfirmation({ boot: { ...on, modal: false }, operation: 'mute' }).required).toBe(false);
  });

  it('asks before turning an explicit off back on, even when the modal default is off', () => {
    const boot = emojiMuteBootFromMeta({
      me: '1',
      emoji_mute_enabled_known: true,
      emoji_mute_enabled: false,
      emoji_mute_enabled_explicit: true,
      emoji_mute_modal: false,
    });

    expect(emojiMuteConfirmation({ boot, operation: 'mute' })).toEqual({
      required: true,
      reenable: true,
      reason: 'reenable',
    });
  });

  it('states that the first mute turns the feature on', () => {
    const boot = {
      availability: 'disabled',
      explicit: false,
      modal: true,
      fetch: false,
      display: 'show',
    };

    expect(emojiMuteConfirmation({ boot, operation: 'mute' })).toEqual({
      required: true,
      reenable: false,
      reason: 'first_enable',
    });
  });

  it('keeps a local enable and disable distinct from the boot meta', () => {
    noteEmojiMuteEnabledLocally();
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    noteEmojiMuteDisabledLocally();
    expect(currentEmojiMuteBoot()).toMatchObject({ availability: 'disabled', explicit: true, fetch: false, display: 'show' });
  });
});

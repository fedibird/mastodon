import initialState from 'mastodon/initial_state_data';

// Unset (the YAML default) and an explicit false are different. A missing
// or non-boolean value is unknown and must not be treated as off: the WebUI
// keeps emoji hidden until a document arrives. The confirmation default is
// on only when the serializer included the key. Pages without it, including
// tests, do not invent a dialog.

const signedIn = meta => !!(meta && (meta.me || meta.access_token));

export function emojiMuteBootFromMeta(meta) {
  const source = meta === undefined ? (initialState && initialState.meta) : meta;

  if (!source || !signedIn(source)) {
    return {
      availability: 'signed_out',
      explicit: false,
      modal: false,
      fetch: false,
      display: 'show',
    };
  }

  const known = source.emoji_mute_enabled_known === true;
  const enabled = source.emoji_mute_enabled;
  const modal = Object.prototype.hasOwnProperty.call(source, 'emoji_mute_modal') && source.emoji_mute_modal !== false;

  if (!known || (enabled !== true && enabled !== false)) {
    return {
      availability: 'unknown',
      explicit: null,
      modal,
      fetch: true,
      display: 'suppress',
    };
  }

  if (enabled === true) {
    return {
      availability: 'enabled',
      explicit: source.emoji_mute_enabled_explicit === true,
      modal,
      fetch: true,
      display: 'suppress',
    };
  }

  return {
    availability: 'disabled',
    explicit: source.emoji_mute_enabled_explicit === true,
    modal,
    fetch: false,
    display: 'show',
  };
}

let runtime = null;

export function currentEmojiMuteBoot() {
  return runtime || emojiMuteBootFromMeta();
}

export function resetEmojiMuteBootForTests() {
  runtime = null;
}

export function noteEmojiMuteEnabledLocally() {
  const current = currentEmojiMuteBoot();
  runtime = {
    ...current,
    availability: 'enabled',
    explicit: true,
    fetch: true,
    display: 'suppress',
  };
  return runtime;
}

export function noteEmojiMutePreferenceConfirming() {
  const current = currentEmojiMuteBoot();
  runtime = {
    ...current,
    availability: 'unknown',
    explicit: current.explicit,
    fetch: true,
    display: 'suppress',
  };
  return runtime;
}

export function noteEmojiMuteDisabledLocally(explicit = true) {
  const current = currentEmojiMuteBoot();
  runtime = {
    ...current,
    availability: 'disabled',
    explicit: explicit === true,
    fetch: false,
    display: 'show',
  };
  return runtime;
}

export function emojiMuteConfirmation({ boot = currentEmojiMuteBoot(), operation } = {}) {
  const explicitOff = boot.availability === 'disabled' && boot.explicit === true;

  if (operation === 'mute' && explicitOff) {
    return { required: true, reenable: true, reason: 'reenable' };
  }

  if (boot.modal !== true) {
    return { required: false, reenable: false, reason: null };
  }

  if (operation === 'mute' && boot.availability === 'disabled') {
    return { required: true, reenable: false, reason: 'first_enable' };
  }

  if (operation === 'mute' || operation === 'unmute') {
    return { required: true, reenable: false, reason: operation };
  }

  return { required: false, reenable: false, reason: null };
}

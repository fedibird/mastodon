import { identityKey, referenceFromPickerEmoji } from './emoji_actions/reference';
import { emojiPickerCandidateHidden, noteUnresolvedPickerCandidate } from './emoji_picker_visibility';

// Skin indexes match emoji-mart: skin 1 is the default native, skin 2 is
// 1F3FB. Finished natives (skin, ZWJ, variation selectors) stay distinct.
const SKINS = ['1F3FA', '1F3FB', '1F3FC', '1F3FD', '1F3FE', '1F3FF'];
const projections = new WeakMap();
const PROJECTION_LIMIT = 4;

function unifiedToNative(unified) {
  return String.fromCodePoint(...String(unified).split('-').map(part => parseInt(part, 16)));
}

export function nativeForEmojiRecord(emojiData, skin) {
  if (!emojiData || emojiData.custom) {
    return null;
  }

  const tone = Number(skin) || 1;
  const toneKey = tone > 1 ? SKINS[tone - 1] : null;
  const variation = toneKey && emojiData.skin_variations && emojiData.skin_variations[toneKey];

  if (variation) {
    if (variation.native) {
      return variation.native;
    }

    if (variation.unified) {
      return unifiedToNative(variation.unified);
    }
  }

  if (emojiData.variations && emojiData.variations.length && !variation) {
    return unifiedToNative(emojiData.variations[0]);
  }

  if (emojiData.native) {
    return emojiData.native;
  }

  if (emojiData.unified) {
    return unifiedToNative(emojiData.unified);
  }

  return null;
}

function emojiRecord(data, id) {
  if (!data || !data.emojis || id === null || id === undefined || id === '') {
    return null;
  }

  const key = data.aliases && data.aliases[id] ? data.aliases[id] : id;

  return data.emojis[key] || null;
}

function unicodeReference(native) {
  if (typeof native !== 'string' || native === '') {
    return null;
  }

  return { kind: 'unicode', native };
}

function customHidden(emoji, visibility) {
  const reference = referenceFromPickerEmoji(emoji);

  if (!reference || !identityKey(reference)) {
    noteUnresolvedPickerCandidate('custom', emoji && (emoji.id || emoji.name));
    return false;
  }

  return emojiPickerCandidateHidden(reference, visibility);
}

function unicodeHidden(native, visibility) {
  const reference = unicodeReference(native);

  if (!reference) {
    noteUnresolvedPickerCandidate('unicode', 'missing-native');
    return false;
  }

  return emojiPickerCandidateHidden(reference, visibility);
}

function recentIdHidden(id, custom, data, skin, visibility) {
  const matches = Array.isArray(custom) ? custom.filter(emoji => emoji && (emoji.id === id || (emoji.short_names || []).includes(id))) : [];

  if (matches.length > 0) {
    return matches.every(emoji => customHidden(emoji, visibility));
  }

  const record = emojiRecord(data, id);

  if (!record) {
    noteUnresolvedPickerCandidate('recent', id);
    return false;
  }

  return unicodeHidden(nativeForEmojiRecord(record, skin), visibility);
}

function deriveData(data, skin, visibility) {
  let changed = false;
  const categories = (data.categories || []).map(category => {
    const emojis = (category.emojis || []).filter(id => {
      const record = emojiRecord(data, id);

      if (!record) {
        noteUnresolvedPickerCandidate('category', id);
        return true;
      }

      return !unicodeHidden(nativeForEmojiRecord(record, skin), visibility);
    });

    if (emojis.length === (category.emojis || []).length) {
      return category;
    }

    changed = true;
    return { ...category, emojis };
  }).filter(category => category.emojis && category.emojis.length > 0);

  if (!changed && categories.length === (data.categories || []).length) {
    return data;
  }

  return {
    ...data,
    categories,
  };
}

function projectReady(props, visibility, data) {
  const skin = props.skin || 1;
  const custom = Array.isArray(props.custom) ? props.custom : [];
  const recent = Array.isArray(props.recent) ? props.recent : null;
  const customIdentity = custom;
  const recentIdentity = recent;
  const cached = projections.get(data) || [];
  const hit = cached.find(entry => entry.signature === visibility.signature && entry.skin === skin && entry.custom === customIdentity && entry.recent === recentIdentity);

  if (hit) {
    return hit.value;
  }

  const nextCustom = custom.filter(emoji => !customHidden(emoji, visibility));
  const nextRecent = recent ? recent.filter(id => !recentIdHidden(id, custom, data, skin, visibility)) : recent;
  const nextData = deriveData(data, skin, visibility);
  const value = {
    custom: nextCustom.length === custom.length ? custom : nextCustom,
    recent: nextRecent,
    data: nextData,
    emojisToShowFilter: emoji => {
      if (!emoji) {
        return false;
      }

      if (emoji.custom) {
        return !customHidden(emoji, visibility);
      }

      return !unicodeHidden(nativeForEmojiRecord(emoji, skin) || emoji.native, visibility);
    },
  };

  projections.set(data, [
    { signature: visibility.signature, skin, custom: customIdentity, recent: recentIdentity, value },
    ...cached.filter(entry => entry !== hit),
  ].slice(0, PROJECTION_LIMIT));

  return value;
}

export function projectStandardPickerProps(props, visibility, data) {
  if (!visibility || !visibility.ready) {
    return {
      ...props,
      custom: [],
      recent: [],
      data: data ? { ...data, categories: [] } : data,
      emojisToShowFilter: () => false,
    };
  }

  if (!visibility.index || visibility.index.size === 0) {
    return {
      ...props,
      data,
    };
  }

  return {
    ...props,
    ...projectReady(props, visibility, data),
  };
}

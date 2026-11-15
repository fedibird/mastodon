export const HASHTAG_MUTE_CONTEXTS = ['home', 'notifications', 'public', 'thread', 'account'];

export const HASHTAG_MUTE_DURATIONS = [0, 300, 1800, 3600, 7200, 10800, 21600, 86400, 259200, 604800];

export const normalizeHashtagName = (raw) => String(raw ?? '').trim().replace(/^[#＃]+/u, '').toLowerCase();

export const findHashtagMute = (filters, hashtag) => {
  if (!filters) {
    return null;
  }

  const name = normalizeHashtagName(hashtag);

  if (!name) {
    return null;
  }

  return filters.valueSeq().find(filter => {
    const tags = filter.get('tags');

    if (!tags || !tags.some) {
      return false;
    }

    return tags.some(tag => normalizeHashtagName(tag.get('name')) === name);
  }) || null;
};

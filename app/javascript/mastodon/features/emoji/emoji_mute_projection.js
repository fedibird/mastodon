// In-memory projection of emoji reaction groups. Definitions are never written
// to localStorage. Unicode identity is the finished string, including
// variation selectors: "‼" and "‼️" do not match.

export const EMOJI_MUTES_APPLY = 'EMOJI_MUTES_APPLY';

const hideRules = mutes => (Array.isArray(mutes) ? mutes : []).filter(rule => rule && rule.effects && rule.effects.hide_reactions);

const emojiOf = rule => rule.emoji || {};

export function unicodeHidden(name, mutes) {
  return hideRules(mutes).some(rule => emojiOf(rule).kind === 'unicode' && emojiOf(rule).native === name);
}

export function partHidden(part, mutes) {
  if (!part) {
    return false;
  }

  return hideRules(mutes).some(rule => {
    const emoji = emojiOf(rule);

    if (!part.custom_emoji_id && !part.domain) {
      return emoji.kind === 'unicode' && emoji.native === (part.native || part.name);
    }

    if (part.domain) {
      return emoji.kind === 'custom' && emoji.scope === 'remote' && emoji.shortcode === part.shortcode &&
        String(emoji.domain || '').toLowerCase() === String(part.domain).toLowerCase();
    }

    return emoji.kind === 'custom' && emoji.scope === 'local' && String(emoji.custom_emoji_id) === String(part.custom_emoji_id);
  });
}

const representativePart = parts => {
  const custom = parts.filter(part => part.custom_emoji_id);
  if (!custom.length) {
    return parts[0];
  }

  return custom.reduce((best, part) => (Number(part.custom_emoji_id) < Number(best.custom_emoji_id) ? part : best));
};

const projectGroup = (group, mutes) => {
  if (!group || typeof group !== 'object') {
    return null;
  }

  if (!Array.isArray(group.parts)) {
    if (!group.domain && !group.url && unicodeHidden(group.name, mutes)) {
      return null;
    }

    return group;
  }

  const parts = group.parts.filter(part => !partHidden(part, mutes));
  if (!parts.length) {
    return null;
  }

  const accountIds = parts.reduce((ids, part) => ids.concat(part.account_ids || []), []);
  const representative = representativePart(parts);
  const next = {
    name: group.name,
    count: accountIds.length,
    account_ids: accountIds,
    me: group.me,
    parts,
  };

  if (representative && !representative.native) {
    ['url', 'static_url', 'domain', 'width', 'height', 'alternate_name', 'ruby'].forEach(key => {
      if (Object.prototype.hasOwnProperty.call(representative, key)) {
        next[key] = representative[key];
      }
    });
  }

  return next;
};

export function projectGroups(groups, mutes) {
  const source = Array.isArray(groups) ? groups : [];
  const next = [];
  let count = 0;

  source.forEach(group => {
    const projected = projectGroup(group, mutes);
    if (!projected) {
      return;
    }

    next.push(projected);
    count += Number(projected.count) || 0;
  });

  return { groups: next, count };
}

// A viewer-independent stream payload. Returns null when the whole name is
// hidden. Custom groups without identity parts are left unchanged.
export function projectStreamPayload(payload, mutes) {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  const projected = projectGroup(payload, mutes);
  if (!projected) {
    return null;
  }

  return { ...projected, status_id: payload.status_id };
}

export function snapshotIsFresh(snapshotRevision, knownRevision) {
  if (snapshotRevision === null || snapshotRevision === undefined || knownRevision === null || knownRevision === undefined) {
    return true;
  }

  return Number(snapshotRevision) >= Number(knownRevision);
}

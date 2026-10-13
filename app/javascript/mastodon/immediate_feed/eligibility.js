import { normalizeHashtagName } from '../utils/status_hashtags';
import { consistentLocalFedibirdGroup } from '../posting_identity/group_destination';
import { hideBotOnPublicTimeline } from '../initial_state';

// TagFeed::LIMIT_PER_MODE. The tag timeline query keeps only this many names
// in each of any/all/none. Later names do not affect publication.
export const TAG_FEED_LIMIT_PER_MODE = 4;

export const IMMEDIATE_FEED_TTL_MS = 30000;

const decline = (reason) => ({ eligible: false, reason });
const accept = () => ({ eligible: true, reason: null });

export function comparableHashtag (name) {
  return normalizeHashtagName(String(name || '').replace(/^[#＃]+/u, ''));
}

const tagToken = (tag) => {
  if (!tag) {
    return '';
  }

  if (typeof tag === 'string') {
    return comparableHashtag(tag);
  }

  return comparableHashtag(tag.name || tag.value || '');
};

export function statusHashtagNames (status) {
  const tags = status && status.tags;

  if (!tags || typeof tags.map !== 'function') {
    return [];
  }

  return tags.map(tagToken).filter(Boolean);
}

// Preserve the first-seen order, then apply the server's per-mode limit.
export function limitedHashtagNames (names) {
  const seen = [];

  (names || []).forEach(name => {
    const normalized = comparableHashtag(name);

    if (normalized && !seen.includes(normalized)) {
      seen.push(normalized);
    }
  });

  return seen.slice(0, TAG_FEED_LIMIT_PER_MODE);
}

const tagValues = (tags, mode) => {
  const list = tags && tags[mode];

  if (!list || typeof list.map !== 'function') {
    return [];
  }

  return list.map(tag => (tag && typeof tag === 'object' ? (tag.value || tag.name) : tag));
};

export function hashtagFilterSignature (filters) {
  const source = filters || {};
  const primary = comparableHashtag(source.primary);
  const anyScope = limitedHashtagNames([source.primary, ...(source.any || [])]);
  const all = limitedHashtagNames(source.all);
  const none = limitedHashtagNames(source.none);

  return [
    'hashtag',
    primary,
    `any:${anyScope.join('\u0001')}`,
    `all:${all.join('\u0001')}`,
    `none:${none.join('\u0001')}`,
  ].join('|');
}

const groupMediaMode = (filters) => {
  if (filters && filters.onlyMedia) {
    return 'only';
  }

  if (filters && filters.withoutMedia) {
    return 'without';
  }

  return 'any';
};

export function groupFilterSignature (filters, localGroup) {
  const tagged = filters && filters.tagged ? comparableHashtag(filters.tagged) : '';
  const media = groupMediaMode(filters);

  return [
    'group',
    filters && filters.groupId ? String(filters.groupId) : '',
    media,
    tagged,
    localGroup ? 'local' : 'remote',
  ].join('|');
}

const accountObject = (status) => {
  const account = status && status.account;

  if (!account || typeof account !== 'object') {
    return null;
  }

  return account;
};

const publicFeedAccountBlocked = (status, hideBot) => {
  const account = accountObject(status);

  if (!account) {
    return null;
  }

  if (account.suspended) {
    return 'suspended';
  }

  if (account.limited) {
    return 'silenced';
  }

  if (hideBot && account.bot) {
    return 'bot';
  }

  return null;
};

// TagFeed publishes through PublicFeed#public_scope (public visibility,
// not suspended, not silenced) plus the any/all/none tag query. Replies are
// included. Reblogs are not delivered to hashtag channels.
export function hashtagStatusEligible (status, filters, { hideBot = hideBotOnPublicTimeline } = {}) {
  if (!status || !filters) {
    return decline('missing');
  }

  const primary = comparableHashtag(filters.primary);

  if (!primary) {
    return decline('missing-tag');
  }

  if (status.reblog) {
    return decline('reblog');
  }

  if (status.visibility !== 'public' || (status.visibility_ex && status.visibility_ex !== 'public')) {
    return decline('visibility');
  }

  const accountReason = publicFeedAccountBlocked(status, hideBot);

  if (accountReason) {
    return decline(accountReason);
  }

  const names = statusHashtagNames(status);
  const anyScope = limitedHashtagNames([filters.primary, ...(filters.any || [])]);
  const all = limitedHashtagNames(filters.all);
  const none = limitedHashtagNames(filters.none);

  if (anyScope.length === 0 || !anyScope.some(tag => names.includes(tag))) {
    return decline('tags-any');
  }

  if (!all.every(tag => names.includes(tag))) {
    return decline('tags-all');
  }

  if (none.some(tag => names.includes(tag))) {
    return decline('tags-none');
  }

  return accept();
}

export function isLocalFedibirdGroupContext (postingContext, groupId) {
  if (!postingContext || groupId === undefined || groupId === null || groupId === '') {
    return false;
  }

  return consistentLocalFedibirdGroup({
    contextKey: postingContext.key,
    postingContextAccountId: groupId,
    resolvedAccountId: groupId,
    groupId,
  });
}

const mentionsGroup = (status, groupId) => {
  const mentions = status && status.mentions;

  if (!mentions || typeof mentions.some !== 'function') {
    return false;
  }

  return mentions.some(mention => mention && String(mention.id) === String(groupId));
};

// GroupFeed shows the original status after the local group reblogs a mention.
// Public and unlisted are always in that feed. Private and direct are not
// inserted here: the group's own reblog visibility can be stricter than the
// post, and that default is not on the client.
export function groupStatusEligible (status, filters, { localGroup = false, blockedByGroup = false, hideBot = hideBotOnPublicTimeline } = {}) {
  if (!localGroup) {
    return decline('remote-group');
  }

  if (!status || !filters || !filters.groupId) {
    return decline('missing-group');
  }

  if (blockedByGroup) {
    return decline('blocked-by-group');
  }

  if (filters.viewPermission === 'denied' || filters.viewPermission === 'unknown') {
    return decline('view-permission');
  }

  if (status.reblog) {
    return decline('reblog');
  }

  if (status.visibility !== 'public' && status.visibility !== 'unlisted') {
    return decline('visibility');
  }

  if (status.visibility_ex && status.visibility_ex !== 'public' && status.visibility_ex !== 'unlisted') {
    return decline('visibility');
  }

  const account = accountObject(status);

  if (account && account.suspended) {
    return decline('suspended');
  }

  if (account && hideBot && account.bot) {
    return decline('bot');
  }

  if (!mentionsGroup(status, filters.groupId)) {
    return decline('group-not-mentioned');
  }

  if (filters.onlyMedia && filters.withoutMedia) {
    return decline('media-conflict');
  }

  const mediaCount = status.media_attachments ? status.media_attachments.length : 0;

  if (filters.onlyMedia && mediaCount === 0) {
    return decline('media-required');
  }

  if (filters.withoutMedia && mediaCount > 0) {
    return decline('media-excluded');
  }

  if (filters.tagged) {
    const wanted = comparableHashtag(filters.tagged);

    if (!wanted) {
      return decline('tagged-unreadable');
    }

    if (!statusHashtagNames(status).includes(wanted)) {
      return decline('tagged-mismatch');
    }
  }

  return accept();
}

export function hashtagFiltersFromParams (primary, tags) {
  return {
    primary,
    any: tagValues(tags, 'any'),
    all: tagValues(tags, 'all'),
    none: tagValues(tags, 'none'),
  };
}

export function buildHashtagImmediateView ({ viewKey, timelineId, primary, tags }) {
  const filters = hashtagFiltersFromParams(primary, tags);

  return {
    viewKey,
    timelineId,
    kind: 'hashtag',
    localGroup: false,
    filters,
    filterSignature: hashtagFilterSignature(filters),
  };
}

export function buildGroupImmediateView ({ viewKey, timelineId, groupId, onlyMedia, withoutMedia, tagged, postingContext, viewPermission = null }) {
  const localGroup = isLocalFedibirdGroupContext(postingContext, groupId);
  const filters = {
    groupId: groupId === undefined || groupId === null ? '' : String(groupId),
    onlyMedia: !!onlyMedia,
    withoutMedia: !!withoutMedia,
    tagged: tagged || null,
    viewPermission: viewPermission || null,
  };

  return {
    viewKey,
    timelineId,
    kind: 'group',
    localGroup,
    filters,
    filterSignature: groupFilterSignature(filters, localGroup),
  };
}

export function immediateStatusDecision (snapshot, status) {
  if (!snapshot || !status) {
    return decline('missing');
  }

  if (snapshot.kind === 'hashtag') {
    return hashtagStatusEligible(status, snapshot.filters);
  }

  if (snapshot.kind === 'group') {
    return groupStatusEligible(status, snapshot.filters, {
      localGroup: snapshot.localGroup,
      blockedByGroup: snapshot.blockedByGroup,
    });
  }

  return decline('unsupported');
}

const plainStatus = (status) => {
  if (!status) {
    return null;
  }

  if (typeof status.toJS === 'function') {
    return status.toJS();
  }

  return status;
};

export function statusMatchesImmediateView (view, status) {
  if (!view || !view.get || !status) {
    return false;
  }

  const snapshot = {
    kind: view.get('kind'),
    localGroup: view.get('localGroup') === true,
    blockedByGroup: false,
    filters: view.get('filters') && view.get('filters').toJS ? view.get('filters').toJS() : view.get('filters'),
  };

  return immediateStatusDecision(snapshot, plainStatus(status)).eligible;
}

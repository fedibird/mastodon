import { getHomeVisibilities, getLimitedVisibilities } from 'mastodon/selectors';
import { readTimelineLayout } from 'mastodon/utils/timeline_layout';
import {
  domainTimelineId,
  groupTimelineId,
  hashtagTimelineId,
  personalTimelineId,
  publicTimelineId,
} from 'mastodon/actions/timeline_ids';
import { emojiReactionedStatusesListKey } from 'mastodon/actions/emoji_reactions';
import { mixColumnKey } from 'mastodon/actions/mix_timelines';

const STATUS_SCOPES = new Set([
  'home',
  'public',
  'community',
  'domain',
  'limited',
  'personal',
  'list',
  'hashtag',
  'group',
  'favourited_statuses',
  'bookmarked_statuses',
  'emoji_reactioned_statuses',
  'account',
  'mixTimeline',
]);

const columnRecord = (state, columnId) => {
  if (!columnId) {
    return null;
  }

  const columns = state.getIn(['settings', 'columns']);
  return columns ? columns.find(column => column.get('uuid') === columnId) || null : null;
};

const columnParam = (column, path, fallback) => {
  if (!column) {
    return fallback;
  }

  const value = column.getIn(['params'].concat(path));
  return value === undefined ? fallback : value;
};

const setting = (state, scope, path, fallback) => {
  const value = state.getIn(['settings', scope].concat(path));
  return value === undefined ? fallback : value;
};

const mediaFlags = (state, scope, column) => {
  const layoutMode = readTimelineLayout(state, column && column.get('uuid'), scope);
  const mediaLayout = layoutMode === 'media';
  const onlyMedia = mediaLayout || columnParam(column, ['other', 'onlyMedia'], setting(state, scope, ['other', 'onlyMedia'], false));
  const withoutMedia = mediaLayout ? false : columnParam(column, ['other', 'withoutMedia'], setting(state, scope, ['other', 'withoutMedia'], false));

  return { layoutMode, onlyMedia: !!onlyMedia, withoutMedia: !!withoutMedia };
};

export const parseFullscreenRoute = (pathname) => {
  const path = pathname || '';
  const read = (expression) => {
    const match = path.match(expression);
    return match ? decodeURIComponent(match[1]) : null;
  };

  return {
    pathname: path,
    listId: read(/^\/timelines\/list\/([^/]+)/),
    tagId: read(/^\/timelines\/tag\/([^/]+)/),
    groupId: read(/^\/timelines\/groups\/([^/]+)/),
    groupTag: read(/^\/timelines\/groups\/[^/]+\/([^/]+)/),
    domain: read(/^\/timelines\/public\/domain\/([^/]+)/),
    mixId: read(/^\/timelines\/mixes\/([^/]+)/),
    accountId: read(/^\/accounts\/([^/]+)/),
    accountTagged: read(/^\/accounts\/[^/]+\/(?:about|posts|with_replies|media)\/([^/]+)/),
    local: /^\/timelines\/public\/local(?:\/|$)/.test(path),
    accountMedia: /^\/accounts\/[^/]+\/media(?:\/|$)/.test(path),
    withReplies: /^\/accounts\/[^/]+\/with_replies(?:\/|$)/.test(path),
    posts: /^\/accounts\/[^/]+\/posts(?:\/|$)/.test(path),
    about: /^\/accounts\/[^/]+\/about(?:\/|$)/.test(path),
    notifications: path === '/notifications',
    direct: path === '/timelines/direct',
    search: path === '/search',
    favourites: path === '/favourites',
    bookmarks: path === '/bookmarks',
    emojiReactions: path === '/emoji_reactions',
  };
};

const surfaceFor = (kind, key) => (
  key ? { kind, key: String(key) } : null
);

const base = (partial) => ({
  supportsStatusLayout: true,
  supportsComposer: true,
  supportsMediaControls: true,
  surface: null,
  listKey: null,
  timelineId: null,
  dataTimelineId: null,
  expand: null,
  expandParams: null,
  accountId: null,
  mixColumnKey: null,
  ...partial,
});

export const fullscreenScopeSupported = (layoutScope, fullscreenKind) => (
  fullscreenKind === 'notifications'
  || fullscreenKind === 'direct'
  || fullscreenKind === 'search'
  || fullscreenKind === 'account_media'
  || STATUS_SCOPES.has(layoutScope)
);

export const resolveFullscreenSource = (state, input = {}) => {
  const column = columnRecord(state, input.columnId);
  const columnType = column ? column.get('id') : null;
  const route = { ...parseFullscreenRoute(input.pathname), ...(input.route || {}) };
  let scope = input.fullscreenKind || input.layoutScope || null;

  if (!scope && route.notifications) {
    scope = 'notifications';
  } else if (!scope && route.direct) {
    scope = 'direct';
  } else if (!scope && route.search) {
    scope = 'search';
  } else if (!scope && route.accountMedia) {
    scope = 'account_media';
  } else if (!scope && route.favourites) {
    scope = 'favourited_statuses';
  } else if (!scope && route.bookmarks) {
    scope = 'bookmarked_statuses';
  } else if (!scope && route.emojiReactions) {
    scope = 'emoji_reactioned_statuses';
  }

  if (!fullscreenScopeSupported(input.layoutScope, scope) && !STATUS_SCOPES.has(scope)) {
    return null;
  }

  const title = input.title || '';
  const icon = input.icon || 'columns';
  const sourceKeyBase = `${scope}:${input.columnId || route.pathname || 'route'}`;

  if (scope === 'notifications' || input.fullscreenKind === 'notifications') {
    return base({
      kind: 'notifications',
      scope: 'notifications',
      sourceKey: `notifications:${input.columnId || 'route'}`,
      supportsStatusLayout: false,
      supportsComposer: false,
      supportsMediaControls: false,
      title,
      icon: icon || 'bell',
    });
  }

  if (scope === 'direct' || input.fullscreenKind === 'direct') {
    return base({
      kind: 'direct',
      scope: 'direct',
      sourceKey: `direct:${input.columnId || 'route'}`,
      supportsStatusLayout: false,
      supportsComposer: false,
      supportsMediaControls: false,
      title,
      icon: icon || 'envelope',
    });
  }

  if (scope === 'search' || input.fullscreenKind === 'search') {
    return base({
      kind: 'search',
      scope: 'search',
      sourceKey: 'search:route',
      supportsStatusLayout: false,
      supportsComposer: false,
      supportsMediaControls: false,
      title,
      icon: 'search',
    });
  }

  if (scope === 'account_media' || input.fullscreenKind === 'account_media' || (input.layoutScope === 'account' && route.accountMedia)) {
    const accountId = (input.params && input.params.accountId) || route.accountId;
    const tagged = (input.params && input.params.tagged) || route.accountTagged || null;

    if (!accountId) {
      return null;
    }

    return base({
      kind: 'account_media',
      scope: 'account',
      sourceKey: `account-media:${accountId}:${tagged || ''}`,
      supportsStatusLayout: false,
      supportsComposer: true,
      supportsMediaControls: true,
      accountId: String(accountId),
      tagged,
      dataTimelineId: `account:${accountId}:media${tagged ? `:${String(tagged).toLocaleLowerCase()}` : ''}`,
      expand: 'account_media',
      expandParams: { accountId: String(accountId), tagged },
      title,
      icon: 'user',
    });
  }

  if (input.layoutScope === 'home' || scope === 'home' || columnType === 'HOME') {
    const layoutMode = readTimelineLayout(state, column && column.get('uuid'), 'home');
    const onlyMedia = layoutMode === 'media';
    const dataTimelineId = onlyMedia ? 'home:media' : 'home';

    return base({
      kind: 'timeline',
      scope: 'home',
      sourceKey: sourceKeyBase,
      layoutMode,
      timelineId: 'home',
      dataTimelineId,
      expand: 'home',
      expandParams: {
        onlyMedia,
        visibilities: getHomeVisibilities(state),
        timelineId: dataTimelineId,
      },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'public' || input.layoutScope === 'community' || columnType === 'PUBLIC' || columnType === 'REMOTE' || columnType === 'COMMUNITY') {
    const flags = mediaFlags(state, 'public', column);
    const onlyRemote = !!(columnType === 'REMOTE' || columnParam(column, ['other', 'onlyRemote'], setting(state, 'public', ['other', 'onlyRemote'], false)));
    const withoutBot = !!columnParam(column, ['other', 'withoutBot'], setting(state, 'public', ['other', 'withoutBot'], false));
    const filters = { onlyRemote, withoutBot, withoutMedia: flags.withoutMedia, onlyMedia: flags.onlyMedia };
    const dataTimelineId = publicTimelineId(filters);

    return base({
      kind: 'timeline',
      scope: 'public',
      sourceKey: `${columnType === 'COMMUNITY' || route.local ? 'community' : 'public'}:${input.columnId || route.pathname || 'route'}`,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'public',
      expandParams: { ...filters, timelineId: dataTimelineId },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'domain' || columnType === 'DOMAIN') {
    const domain = (input.params && input.params.domain) || columnParam(column, ['domain'], null) || route.domain;
    const flags = mediaFlags(state, 'domain', column);
    const withoutBot = !!columnParam(column, ['other', 'withoutBot'], setting(state, 'domain', ['other', 'withoutBot'], false));

    if (!domain) {
      return null;
    }

    const filters = { withoutBot, withoutMedia: flags.withoutMedia, onlyMedia: flags.onlyMedia };
    const dataTimelineId = domainTimelineId(domain, filters);

    return base({
      kind: 'timeline',
      scope: 'domain',
      sourceKey: `domain:${domain}:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'domain',
      expandParams: { domain, ...filters, timelineId: dataTimelineId },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'limited' || columnType === 'LIMITED') {
    const layoutMode = readTimelineLayout(state, column && column.get('uuid'), 'limited');
    const onlyMedia = layoutMode === 'media';
    const dataTimelineId = onlyMedia ? 'limited:media' : 'limited';

    return base({
      kind: 'timeline',
      scope: 'limited',
      sourceKey: sourceKeyBase,
      layoutMode,
      timelineId: 'limited',
      dataTimelineId,
      expand: 'limited',
      expandParams: {
        onlyMedia,
        visibilities: getLimitedVisibilities(state),
        timelineId: dataTimelineId,
      },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'personal' || columnType === 'PERSONAL') {
    const flags = mediaFlags(state, 'personal', column);
    const dataTimelineId = personalTimelineId({ onlyMedia: flags.onlyMedia, withoutMedia: flags.withoutMedia });

    return base({
      kind: 'timeline',
      scope: 'personal',
      sourceKey: sourceKeyBase,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'personal',
      expandParams: { onlyMedia: flags.onlyMedia, withoutMedia: flags.withoutMedia, timelineId: dataTimelineId },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'list' || columnType === 'LIST') {
    const id = (input.params && input.params.id) || columnParam(column, ['id'], null) || route.listId;
    const flags = mediaFlags(state, 'list', column);

    if (!id) {
      return null;
    }

    const dataTimelineId = `list:${id}${flags.onlyMedia ? ':media' : ''}`;

    return base({
      kind: 'timeline',
      scope: 'list',
      sourceKey: `list:${id}:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'list',
      expandParams: { id: String(id), onlyMedia: flags.onlyMedia, timelineId: dataTimelineId },
      surface: surfaceFor('list', id),
      title,
      icon,
    });
  }

  if (input.layoutScope === 'hashtag' || columnType === 'HASHTAG') {
    const id = (input.params && input.params.id) || columnParam(column, ['id'], null) || route.tagId;
    const flags = mediaFlags(state, 'hashtag', column);

    if (!id) {
      return null;
    }

    const dataTimelineId = hashtagTimelineId(id, { onlyMedia: flags.onlyMedia });

    return base({
      kind: 'timeline',
      scope: 'hashtag',
      sourceKey: `hashtag:${id}:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'hashtag',
      expandParams: { id: String(id), onlyMedia: flags.onlyMedia, timelineId: dataTimelineId },
      surface: surfaceFor('hashtag', id),
      title,
      icon,
    });
  }

  if (input.layoutScope === 'group' || columnType === 'GROUP') {
    const id = (input.params && input.params.id) || columnParam(column, ['id'], null) || route.groupId;
    const tagged = (input.params && input.params.tagged) || columnParam(column, ['other', 'tagged'], null) || columnParam(column, ['tagged'], null) || route.groupTag;
    const flags = mediaFlags(state, 'group', column);

    if (!id) {
      return null;
    }

    const filters = { withoutMedia: flags.withoutMedia, onlyMedia: flags.onlyMedia, tagged };
    const dataTimelineId = groupTimelineId(id, filters);

    return base({
      kind: 'timeline',
      scope: 'group',
      sourceKey: `group:${id}:${tagged || ''}:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      timelineId: dataTimelineId,
      dataTimelineId,
      expand: 'group',
      expandParams: { id: String(id), ...filters, timelineId: dataTimelineId },
      surface: surfaceFor('group', id),
      title,
      icon,
    });
  }

  if (input.layoutScope === 'favourited_statuses' || scope === 'favourited_statuses' || columnType === 'FAVOURITES') {
    const flags = mediaFlags(state, 'favourited_statuses', column);

    return base({
      kind: 'status_list',
      scope: 'favourited_statuses',
      sourceKey: `favourites:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      listKey: 'favourites',
      expand: 'favourites',
      title,
      icon,
    });
  }

  if (input.layoutScope === 'bookmarked_statuses' || scope === 'bookmarked_statuses' || columnType === 'BOOKMARKS') {
    const flags = mediaFlags(state, 'bookmarked_statuses', column);

    return base({
      kind: 'status_list',
      scope: 'bookmarked_statuses',
      sourceKey: `bookmarks:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      listKey: 'bookmarks',
      expand: 'bookmarks',
      title,
      icon,
    });
  }

  if (input.layoutScope === 'emoji_reactioned_statuses' || scope === 'emoji_reactioned_statuses' || columnType === 'EMOJI_REACTIONS') {
    const flags = mediaFlags(state, 'emoji_reactioned_statuses', column);

    return base({
      kind: 'emoji_reactions',
      scope: 'emoji_reactioned_statuses',
      sourceKey: `emoji:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      listKey: emojiReactionedStatusesListKey(input.columnId),
      expand: 'emoji_reactions',
      title,
      icon,
    });
  }

  if (input.layoutScope === 'account') {
    const accountId = (input.params && input.params.accountId) || route.accountId;
    const tagged = (input.params && input.params.tagged) || route.accountTagged || null;
    const flags = mediaFlags(state, 'account', column);
    const layoutMode = flags.layoutMode === 'media' ? 'normal' : flags.layoutMode;
    const withReplies = !!(input.params && input.params.withReplies) || route.withReplies;
    const posts = !!(input.params && input.params.posts) || route.posts;
    const about = !!(input.params && input.params.about) || route.about;
    const advancedMode = state.getIn(['settings', 'account', 'other', 'advancedMode'], false);
    const withoutReblogs = !!(advancedMode && state.getIn(['settings', 'account', 'other', 'withoutReblogs'], false));
    const showPostsInAbout = state.getIn(['settings', 'account', 'other', 'showPostsInAbout'], true);
    const path = `${accountId}${withReplies ? ':with_replies' : ''}${withoutReblogs ? ':without_reblogs' : ''}${tagged ? `:${tagged}` : ''}`;

    if (!accountId) {
      return null;
    }

    return base({
      kind: 'account',
      scope: 'account',
      sourceKey: `account:${path}:${input.columnId || 'route'}`,
      layoutMode,
      accountId: String(accountId),
      tagged,
      timelineId: 'account',
      dataTimelineId: `account:${path}`,
      featuredTimelineId: (withReplies || posts) ? null : `account:${accountId}:pinned${tagged ? `:${tagged}` : ''}`,
      expand: (about && advancedMode && !showPostsInAbout && !tagged) ? null : 'account',
      expandParams: { accountId: String(accountId), withReplies, tagged, withoutReblogs, onlyMedia: false },
      title,
      icon,
    });
  }

  if (input.layoutScope === 'mixTimeline' || columnType === 'MIX') {
    const mixId = (input.params && input.params.id) || columnParam(column, ['id'], null) || route.mixId;
    const flags = mediaFlags(state, 'mixTimeline', column);

    if (!mixId) {
      return null;
    }

    return base({
      kind: 'mix',
      scope: 'mixTimeline',
      sourceKey: `mix:${mixId}:${input.columnId || 'route'}`,
      layoutMode: flags.layoutMode,
      mixId: String(mixId),
      mixColumnKey: mixColumnKey(input.columnId, mixId),
      expand: 'mix',
      title,
      icon,
    });
  }

  return null;
};

import { createSelector } from 'reselect';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { me, enableLimitedTimeline, hideDirectFromTimeline, hidePersonalFromTimeline, maxFrequentlyUsedEmojis } from '../initial_state';
import { buildCustomEmojis, categoriesFromEmojis } from 'mastodon/features/emoji/emoji';

const getAccountBase         = (state, id) => state.getIn(['accounts', id], null);
const getAccountCounters     = (state, id) => state.getIn(['accounts_counters', id], null);
const getAccountRelationship = (state, id) => state.getIn(['relationships', id], null);
const getAccountMoved        = (state, id) => state.getIn(['accounts', state.getIn(['accounts', id, 'moved'])]);

export const makeGetAccount = () => {
  return createSelector([getAccountBase, getAccountCounters, getAccountRelationship, getAccountMoved], (base, counters, relationship, moved) => {
    if (base === null) {
      return null;
    }

    return base.merge(counters).withMutations(map => {
      map.set('relationship', relationship);
      map.set('moved', moved);
    });
  });
};

const toServerSideType = columnType => {
  switch (columnType) {
  case 'home':
  case 'notifications':
  case 'public':
  case 'thread':
  case 'account':
    return columnType;
  default:
    if (columnType.indexOf('list:') > -1) {
      return 'home';
    } else {
      return 'public'; // community, account, hashtag
    }
  }
};

const escapeRegExp = string =>
  string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); // $& means the whole matched string

const regexFromFilters = filters => {
  if (filters.size === 0) {
    return null;
  }

  return new RegExp(filters.valueSeq().map(filter => {
    let expr = escapeRegExp(filter.get('phrase'));

    if (filter.get('whole_word')) {
      if (/^[\w]/.test(expr)) {
        expr = `\\b${expr}`;
      }

      if (/[\w]$/.test(expr)) {
        expr = `${expr}\\b`;
      }
    }

    return expr;
  }).join('|'), 'i');
};

// Kept for notifications (PR C will migrate them to FilterResult).
// v2 Filter entities do not include phrase/irreversible, so this helper
// only matches legacy v1-shaped filters if any remain in state.
const makeGetFiltersRegex = () => {
  return (state, { contextType }) => {
    if (!contextType) return ImmutableList();

    const serverSideType = toServerSideType(contextType);
    const now = new Date();
    const filters = state.get('filters', ImmutableMap()).filter(filter => {
      const phrase = filter.get('phrase');
      const context = filter.get('context');
      const expiresAt = filter.get('expires_at');

      return phrase && context && context.includes(serverSideType) && (expiresAt === null || new Date(expiresAt) > now);
    });

    const dropRegex = regexFromFilters(filters.filter(filter => filter.get('irreversible')));
    const regex = regexFromFilters(filters);
    return [dropRegex, regex];
  };
};

export const getFiltersRegex = makeGetFiltersRegex();

const getFilters = (state, { contextType }) => {
  if (!contextType) return null;

  const serverSideType = toServerSideType(contextType);
  const now = new Date();

  return state.get('filters', ImmutableMap()).filter(filter => {
    const context = filter.get('context');
    const expiresAt = filter.get('expires_at');

    return context && context.includes(serverSideType) && (expiresAt === null || expiresAt > now);
  });
};

export const makeGetStatus = () => {
  return createSelector(
    [
      (state, { id }) =>                               state.getIn(['statuses', id], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', id,                                                                             'account'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', id,                                                                             'account']), 'moved'], null),
      (state, { id }) => state.getIn(['relationships', state.getIn(['statuses', id,                                                                             'account'])], null),

      (state, { id }) =>                               state.getIn(['statuses', state.getIn(['statuses', id,                                      'reblog'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', id,                                      'reblog']),   'account'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', id,                                      'reblog']),   'account']), 'moved'], null),
      (state, { id }) => state.getIn(['relationships', state.getIn(['statuses', state.getIn(['statuses', id,                                      'reblog']),   'account'])], null),

      (state, { id }) =>                               state.getIn(['statuses', state.getIn(['statuses', id,                                      'quote_id'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', id,                                      'quote_id']), 'account'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', id,                                      'quote_id']), 'account']), 'moved'], null),
      (state, { id }) => state.getIn(['relationships', state.getIn(['statuses', state.getIn(['statuses', id,                                      'quote_id']), 'account'])], null),

      (state, { id }) =>                               state.getIn(['statuses', state.getIn(['statuses', state.getIn(['statuses', id, 'reblog']), 'quote_id'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', state.getIn(['statuses', id, 'reblog']), 'quote_id']), 'account'])], null),
      (state, { id }) => state.getIn(['accounts',      state.getIn(['statuses', state.getIn(['statuses', state.getIn(['statuses', id, 'reblog']), 'quote_id']), 'account']), 'moved'], null),
      (state, { id }) => state.getIn(['relationships', state.getIn(['statuses', state.getIn(['statuses', state.getIn(['statuses', id, 'reblog']), 'quote_id']), 'account'])], null),

      getFilters,
    ],

    (
      statusBase,
      accountBase,
      moved,
      relationship,

      statusReblog,
      accountReblog,
      reblogMoved,
      reblogRelationship,

      statusQuote,
      accountQuote,
      quoteMoved,
      quoteRelationship,

      statusReblogQuote,
      accountReblogQuote,
      reblogQuoteMoved,
      reblogQuoteRelationship,

      filters,
    ) => {
      if (!statusBase || !accountBase) {
        return null;
      }

      let matchedFilters = false;

      if ((accountReblog || accountBase).get('id') !== me && filters) {
        let filterResults = statusReblog?.get('filtered') || statusBase.get('filtered') || ImmutableList();

        if (filterResults.some(result => filters.getIn([result.get('filter'), 'filter_action']) === 'hide')) {
          return null;
        }

        filterResults = filterResults.filter(result => filters.has(result.get('filter')));

        if (!filterResults.isEmpty()) {
          matchedFilters = filterResults.map(result => filters.getIn([result.get('filter'), 'title']));
        }
      }

      if (statusReblogQuote && accountReblogQuote) {
        accountReblogQuote = accountReblogQuote.withMutations(map => {
          map.set('relationship', reblogQuoteRelationship);
          map.set('moved', reblogQuoteMoved);
        });
        statusReblogQuote = statusReblogQuote.withMutations(map => {
          map.set('account', accountReblogQuote);
        });
      }

      if (statusReblog  && accountReblog) {
        accountReblog = accountReblog.withMutations(map => {
          map.set('relationship', reblogRelationship);
          map.set('moved', reblogMoved);
        });
        statusReblog = statusReblog.withMutations(map => {
          map.set('quote', statusReblogQuote);
          map.set('account', accountReblog);
        });
      }

      if (statusQuote && accountQuote) {
        accountQuote = accountQuote.withMutations(map => {
          map.set('relationship', quoteRelationship);
          map.set('moved', quoteMoved);
        });
        statusQuote = statusQuote.withMutations(map => {
          map.set('account', accountQuote);
        });
      }

      accountBase = accountBase.withMutations(map => {
        map.set('relationship', relationship);
        map.set('moved', moved);
      });

      statusBase = statusBase.withMutations(map => {
        map.set('reblog', statusReblog);
        map.set('quote', statusQuote);
        map.set('account', accountBase);
        map.set('matched_filters', matchedFilters);
      });

      return statusBase;
    },
  );
};

export const makeGetPictureInPicture = () => {
  return createSelector([
    (state, { id }) => state.get('picture_in_picture').statusId === id,
    (state) => state.getIn(['meta', 'layout']) !== 'mobile',
  ], (inUse, available) => ImmutableMap({
    inUse: inUse && available,
    available,
  }));
};

const getAlertsBase = state => state.get('alerts');

export const getAlerts = createSelector([getAlertsBase], (base) => {
  let arr = [];

  base.forEach(item => {
    arr.push({
      message: item.get('message'),
      message_values: item.get('message_values'),
      title: item.get('title'),
      key: item.get('key'),
      dismissAfter: 5000,
      barStyle: {
        zIndex: 200,
      },
    });
  });

  return arr;
});

export const makeGetNotification = () => {
  return createSelector([
    (_, base)             => base,
    (state, _, accountId) => state.getIn(['accounts', accountId]),
    (state, _, targetAccountId) => targetAccountId ? state.getIn(['accounts', targetAccountId]) : null,
  ], (base, account, target_account) => {
    return base.set('account', account).set('target_account', target_account);
  });
};

export const getAccountGallery = createSelector([
  (state, id) => state.getIn(['timelines', `account:${id}:media`, 'items'], ImmutableList()),
  state       => state.get('statuses'),
  (state, id) => state.getIn(['accounts', id]),
], (statusIds, statuses, account) => {
  let medias = ImmutableList();

  statusIds.forEach(statusId => {
    const status = statuses.get(statusId);
    medias = medias.concat(status.get('media_attachments').map(media => media.set('status', status).set('account', account)));
  });

  return medias;
});

export const getHomeVisibilities = createSelector(
  state => state.getIn(['settings', 'home', 'shows']),
  shows => (!enableLimitedTimeline ? [
    'public',
    'unlisted',
    'private',
    'limited',
    !hideDirectFromTimeline ? 'direct'  : null,
    !hidePersonalFromTimeline ? 'personal' : null,
  ] : [
    'public',
    'unlisted',
    shows.get('private') ? 'private' : null,
    shows.get('limited') ? 'limited' : null,
    shows.get('direct') && !hideDirectFromTimeline ? 'direct'  : null,
    shows.get('personal') && !hidePersonalFromTimeline ? 'personal' : null,
  ]).filter(x => !!x),
);

export const getLimitedVisibilities = createSelector(
  state => state.getIn(['settings', 'limited', 'shows']),
  shows => !enableLimitedTimeline ? [] : [
    shows.get('private') ? 'private' : null,
    shows.get('limited') ? 'limited' : null,
    shows.get('direct')  ? 'direct'  : null,
    shows.get('personal') ? 'personal' : null,
  ].filter(x => !!x),
);

export const getPersonalVisibilities = createSelector(
  state => state.getIn(['settings', 'personal', 'shows']),
);

const DEFAULTS = [
  '+1',
  'grinning',
  'kissing_heart',
  'heart_eyes',
  'laughing',
  'stuck_out_tongue_winking_eye',
  'sweat_smile',
  'joy',
  'yum',
  'disappointed',
  'thinking_face',
  'weary',
  'sob',
  'sunglasses',
  'heart',
  'ok_hand',
];

export const getPickersEmoji = createSelector(
  state => state.get('custom_emojis'),
  custom_emojis => {
    const emojis = custom_emojis.filter(e => e.get('visible_in_picker'));

    return ImmutableMap({
      custom_emojis: buildCustomEmojis(emojis),
      categories: categoriesFromEmojis(emojis),
    });
  },
);

export const getFrequentlyUsedEmojis = createSelector([
  state => state.getIn(['settings', 'frequentlyUsedEmojis'], ImmutableMap()),
], emojiCounters => {
  let emojis = emojiCounters
    .keySeq()
    .sort((a, b) => emojiCounters.get(a) - emojiCounters.get(b))
    .reverse()
    .slice(0, maxFrequentlyUsedEmojis)
    .toArray();

  if (emojis.length < maxFrequentlyUsedEmojis) {
    let uniqueDefaults = DEFAULTS.filter(emoji => !emojis.includes(emoji));
    emojis = emojis.concat(uniqueDefaults.slice(0, maxFrequentlyUsedEmojis - emojis.length));
  }

  return emojis;
});


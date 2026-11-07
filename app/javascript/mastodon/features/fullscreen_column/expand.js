import {
  expandAccountMediaTimeline,
  expandAccountTimeline,
  expandDomainTimeline,
  expandGroupTimeline,
  expandHashtagTimeline,
  expandHomeTimeline,
  expandLimitedTimeline,
  expandListTimeline,
  expandPersonalTimeline,
  expandPublicTimeline,
} from 'mastodon/actions/timelines';
import { expandFavouritedStatuses } from 'mastodon/actions/favourites';
import { expandBookmarkedStatuses } from 'mastodon/actions/bookmarks';
import { expandEmojiReactionedStatuses } from 'mastodon/actions/emoji_reactions';
import { loadMixTimeline } from 'mastodon/actions/mix_timelines';
import { List as ImmutableList } from 'immutable';

const plainParams = (source) => {
  const params = source.get('expandParams');
  return params && params.toJS ? params.toJS() : {};
};

const findMix = (state, id) => {
  if (!id) {
    return null;
  }

  return state.getIn(['settings', 'mixes'], ImmutableList()).find(item => item && String(item.get('id')) === String(id)) || null;
};

export const expandFullscreenSource = (dispatch, getState, source, maxId) => {
  if (!source) {
    return;
  }

  const expand = source.get('expand');
  const params = plainParams(source);

  switch (expand) {
  case 'home':
    dispatch(expandHomeTimeline({ ...params, maxId }));
    return;
  case 'public':
    dispatch(expandPublicTimeline({ ...params, maxId }));
    return;
  case 'domain':
    dispatch(expandDomainTimeline(params.domain, { ...params, maxId }));
    return;
  case 'limited':
    dispatch(expandLimitedTimeline({ ...params, maxId }));
    return;
  case 'personal':
    dispatch(expandPersonalTimeline({ ...params, maxId }));
    return;
  case 'list':
    dispatch(expandListTimeline(params.id, { ...params, maxId }));
    return;
  case 'hashtag':
    dispatch(expandHashtagTimeline(params.id, { ...params, maxId }));
    return;
  case 'group':
    dispatch(expandGroupTimeline(params.id, { ...params, maxId }));
    return;
  case 'account':
    dispatch(expandAccountTimeline(params.accountId, { ...params, maxId, onlyMedia: false }));
    return;
  case 'account_media':
    dispatch(expandAccountMediaTimeline(params.accountId, { maxId, tagged: params.tagged }));
    return;
  case 'favourites':
    dispatch(expandFavouritedStatuses());
    return;
  case 'bookmarks':
    dispatch(expandBookmarkedStatuses());
    return;
  case 'emoji_reactions':
    dispatch(expandEmojiReactionedStatuses(source.get('listKey')));
    return;
  case 'mix':
    dispatch(loadMixTimeline(source.get('mixColumnKey'), findMix(getState(), source.get('mixId')), { extend: true }));
    return;
  default:
  }
};

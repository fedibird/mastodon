import {
  REBLOG_REQUEST,
  REBLOG_FAIL,
  UNREBLOG_REQUEST,
  UNREBLOG_FAIL,
  FAVOURITE_REQUEST,
  FAVOURITE_FAIL,
  UNFAVOURITE_REQUEST,
  UNFAVOURITE_FAIL,
  BOOKMARK_REQUEST,
  BOOKMARK_FAIL,
  UNBOOKMARK_REQUEST,
  UNBOOKMARK_FAIL,
  EMOJI_REACTION_REQUEST,
  EMOJI_REACTION_FAIL,
  UN_EMOJI_REACTION_REQUEST,
  UN_EMOJI_REACTION_FAIL,
  EMOJI_REACTION_UPDATE,
} from '../actions/interactions';
import {
  STATUS_MUTE_SUCCESS,
  STATUS_UNMUTE_SUCCESS,
  STATUS_REVEAL,
  STATUS_HIDE,
  STATUS_COLLAPSE,
  STATUS_TRANSLATE_SUCCESS,
  STATUS_TRANSLATE_UNDO,
  STATUS_TRANSLATE_REQUEST,
  STATUS_TRANSLATE_FAIL,
  STATUS_TRANSLATE_SET_MODE,
  STATUS_TRANSLATION_ASSUMPTION,
  STATUS_TRANSLATION_TARGET,
} from '../actions/statuses';
import { TIMELINE_DELETE } from '../actions/timelines';
import { STATUS_IMPORT, STATUSES_IMPORT } from '../actions/importer';
import { EXTERNAL_LINK_BOOST_CHANGED } from '../actions/external_boosts';
import compareId from '../compare_id';
import { protectBoostState, revisionOfImmutable } from '../external_boosts/revision';
import { normalizeStatusTranslation } from '../actions/importer/normalizer';
import { me } from '../initial_state';
import { Map as ImmutableMap, List, fromJS } from 'immutable';

const importStatus = (state, status) => {
  if (state.getIn([status.in_reply_to_id, 'replies_count'], null) === 0) {
    state = state.setIn([status.in_reply_to_id, 'replies_count'], 1);
  }
  // A projection of the signed-in user carries a revision beside `reblogged`.
  // An older payload keeps the pair already applied; everything else in it is
  // imported as before. A status with no revision is not touched.
  return state.set(status.id, fromJS(protectBoostState(state.get(status.id), status)));
};

const importStatuses = (state, statuses) =>
  state.withMutations(mutable => statuses.forEach(status => importStatus(mutable, status)));

// The share state of a projection (E4). `reblogged` of such a status is ordered
// by a server revision, so the optimistic click and its rollback only act while
// no newer revision has been applied.
const hasBoostRevision = (state, id) => revisionOfImmutable(state.get(id)) !== null;

const optimisticBoost = (state, id, value) => {
  const status = state.get(id);

  return state.setIn([id, 'reblogged'], value).setIn([id, 'link_boost_optimistic'], status.getIn(['fedibird_external', 'link_boost_revision']));
};

const rollbackBoost = (state, id, value) => {
  const status = state.get(id);
  const base = status.get('link_boost_optimistic');

  if (base === undefined) {
    return state;
  }

  const unchanged = revisionOfImmutable(status) === base;

  return (unchanged ? state.setIn([id, 'reblogged'], value) : state).deleteIn([id, 'link_boost_optimistic']);
};

const applyBoostEvent = (state, action) => {
  const status = state.get(action.statusId);

  if (!status) {
    return state;
  }

  const current = revisionOfImmutable(status) || '0';

  if (compareId(action.revision, current) <= 0) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn([action.statusId, 'reblogged'], action.reblogged);
    map.setIn([action.statusId, 'fedibird_external', 'link_boost_revision'], action.revision);
    map.deleteIn([action.statusId, 'link_boost_optimistic']);
  });
};

const deleteStatus = (state, id, references, quotes) => {
  references?.forEach(ref => {
    state = deleteStatus(state, ref, [], []);
  });

  quotes?.forEach(ref => {
    state = state.setIn([ref, 'quote_id'], null).setIn([ref, 'quote'], null);
  });

  return state.delete(id);
};

const updateEmojiReaction = (state, id, name, domain, url, static_url, updater) => state.update(id, status => {
  return status.update('emoji_reactions', emojiReactions => {
    const idx = emojiReactions.findIndex(emojiReaction => emojiReaction.get('name') === name);

    if (idx > -1) {
      return emojiReactions.update(idx, emojiReactions => updater(emojiReactions));
    }

    return emojiReactions.push(updater(fromJS({ name, domain, url, static_url, count: 0, account_ids: [] })));
  });
});

const updateEmojiReactionCount = (state, emojiReaction) => updateEmojiReaction(state, emojiReaction.status_id, emojiReaction.name, emojiReaction.domain, emojiReaction.url, emojiReaction.static_url, x => x.set('count', emojiReaction.count).set('account_ids', new List(emojiReaction.account_ids)));

const addEmojiReaction = (state, id, name, domain, url, static_url) => updateEmojiReaction(state, id, name, domain, url, static_url, x => x.update('count', y => y + 1).update('account_ids', z => z.push(me)));

const removeEmojiReaction = (state, id, name, domain, url, static_url) => updateEmojiReaction(state, id, name, domain, url, static_url, x => x.update('count', y => y - 1).update('account_ids', z => z.filter(id => id !== me)));

const statusTranslationMode = mode => (mode === 'bilingual' || mode === 'original') ? mode : 'translated';

const statusTranslateRequest = (state, id, requestId, contentSignature) => {
  if (!state.get(id)) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn([id, 'translationPending'], true);

    if (requestId) {
      map.setIn([id, 'translationRequestId'], requestId);
    }

    if (contentSignature && typeof contentSignature.full === 'string') {
      map.setIn([id, 'translationContentSignature'], contentSignature.full);
      map.setIn([id, 'translationStatusSignature'], contentSignature.status);
    }
  });
};

const translationRequestCurrent = (status, requestId) => status.get('translationRequestId') === requestId;

const statusTranslateSuccess = (state, id, translation, domain, mode, requestId, contentStatusId) => {
  const status = state.get(id);

  if (!status || !translationRequestCurrent(status, requestId)) {
    return state;
  }

  // A personal boost is authorized as the wrapper, but its text, emoji, and
  // media live on the boosted status. Keep the translation on the wrapper so
  // a different permission context cannot see it on the proper status.
  const contentStatus = contentStatusId && contentStatusId !== id ? state.get(contentStatusId) : null;

  return state.withMutations(map => {
    const normalized = normalizeStatusTranslation(translation, contentStatus || status, domain);

    if (contentStatus && Array.isArray(translation.media_attachments)) {
      normalized.media_attachments = translation.media_attachments.map(item => ({
        id: item.id,
        description: item.description,
      }));
    }

    map.setIn([id, 'translation'], fromJS(normalized));
    map.setIn([id, 'translationPending'], false);
    map.deleteIn([id, 'translationRequestId']);
    map.setIn([id, 'translationMode'], statusTranslationMode(mode));

    if (contentStatus) {
      return;
    }

    const list = map.getIn([id, 'media_attachments']);

    if (translation.media_attachments && list) {
      translation.media_attachments.forEach(item => {
        const index = list.findIndex(i => i.get('id') === item.id);

        if (index > -1) {
          map.setIn([id, 'media_attachments', index, 'translation'], fromJS({ description: item.description }));
        }
      });
    }
  });
};

const statusTranslateFail = (state, id, requestId) => {
  const status = state.get(id);

  if (!status || !translationRequestCurrent(status, requestId)) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn([id, 'translationPending'], false);
    map.deleteIn([id, 'translationRequestId']);
  });
};

const statusTranslateSetMode = (state, id, mode) => {
  if (!state.get(id) || !['original', 'translated', 'bilingual'].includes(mode)) {
    return state;
  }

  return state.setIn([id, 'translationMode'], mode);
};

const statusTranslationAssumption = (state, id) => {
  if (!state.get(id)) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn([id, 'translationPending'], false);
    map.deleteIn([id, 'translationRequestId']);

    if (map.getIn([id, 'translation'])) {
      map.setIn([id, 'translationMode'], 'original');
    }
  });
};

const invalidateTranslationTarget = (state) => state.withMutations(map => {
  map.forEach((status, id) => {
    if (!status || typeof status.get !== 'function') {
      return;
    }

    map.setIn([id, 'translationPending'], false);
    map.deleteIn([id, 'translationRequestId']);

    if (status.get('translation')) {
      map.setIn([id, 'translationMode'], 'original');
    }
  });
});

const statusTranslateUndo = (state, id) => {
  if (!state.get(id)) {
    return state;
  }

  return state.withMutations(map => {
    map.deleteIn([id, 'translation']);
    map.deleteIn([id, 'translationMode']);
    map.deleteIn([id, 'translationRequestId']);
    map.deleteIn([id, 'translationContentSignature']);
    map.deleteIn([id, 'translationStatusSignature']);
    map.setIn([id, 'translationPending'], false);

    const media = map.getIn([id, 'media_attachments']);

    if (media) {
      media.forEach((_item, index) => map.deleteIn([id, 'media_attachments', index, 'translation']));
    }
  });
};

const initialState = ImmutableMap();

export default function statuses(state = initialState, action) {
  switch(action.type) {
  case STATUS_IMPORT:
    return importStatus(state, action.status);
  case STATUSES_IMPORT:
    return importStatuses(state, action.statuses);
  case FAVOURITE_REQUEST:
    return state.setIn([action.status.get('id'), 'favourited'], true);
  case FAVOURITE_FAIL:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'favourited'], false);
  case UNFAVOURITE_REQUEST:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'favourited'], false);
  case UNFAVOURITE_FAIL:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'favourited'], true);
  case BOOKMARK_REQUEST:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'bookmarked'], true);
  case BOOKMARK_FAIL:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'bookmarked'], false);
  case UNBOOKMARK_REQUEST:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'bookmarked'], false);
  case UNBOOKMARK_FAIL:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'bookmarked'], true);
  case EMOJI_REACTION_UPDATE:
    return state.get(action.emojiReaction.status_id) === undefined ? state : updateEmojiReactionCount(state, action.emojiReaction);
  case EMOJI_REACTION_REQUEST:
  case UN_EMOJI_REACTION_FAIL:
    if (state.get(action.status.get('id')) !== undefined) {
      state = addEmojiReaction(state, action.status.get('id'), action.name, action.domain, action.url, action.static_url);
    }
    return state;
  case UN_EMOJI_REACTION_REQUEST:
  case EMOJI_REACTION_FAIL:
    if (state.get(action.status.get('id')) !== undefined) {
      state = removeEmojiReaction(state, action.status.get('id'), action.name, action.domain, action.url, action.static_url);
    }
    return state;
  case EXTERNAL_LINK_BOOST_CHANGED:
    return applyBoostEvent(state, action);
  case REBLOG_REQUEST:
    if (hasBoostRevision(state, action.status.get('id'))) {
      return optimisticBoost(state, action.status.get('id'), true);
    }
    return state.setIn([action.status.get('id'), 'reblogged'], true);
  case REBLOG_FAIL:
    if (hasBoostRevision(state, action.status.get('id'))) {
      return rollbackBoost(state, action.status.get('id'), false);
    }
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'reblogged'], false);
  case UNREBLOG_REQUEST:
    if (hasBoostRevision(state, action.status.get('id'))) {
      return optimisticBoost(state, action.status.get('id'), false);
    }
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'reblogged'], false);
  case UNREBLOG_FAIL:
    if (hasBoostRevision(state, action.status.get('id'))) {
      return rollbackBoost(state, action.status.get('id'), true);
    }
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'reblogged'], true);
  case STATUS_MUTE_SUCCESS:
    return state.setIn([action.id, 'muted'], true);
  case STATUS_UNMUTE_SUCCESS:
    return state.setIn([action.id, 'muted'], false);
  case STATUS_REVEAL:
    return state.withMutations(map => {
      action.ids.forEach(id => {
        if (!(state.get(id) === undefined)) {
          map.setIn([id, 'hidden'], false);
        }
      });
    });
  case STATUS_HIDE:
    return state.withMutations(map => {
      action.ids.forEach(id => {
        if (!(state.get(id) === undefined)) {
          map.setIn([id, 'hidden'], true);
        }
      });
    });
  case STATUS_COLLAPSE:
    return state.setIn([action.id, 'collapsed'], action.isCollapsed);
  case TIMELINE_DELETE:
    return deleteStatus(state, action.id, action.references, action.quotes);
  case STATUS_TRANSLATE_REQUEST:
    return statusTranslateRequest(state, action.id, action.translationRequestId, action.contentSignature);
  case STATUS_TRANSLATE_SUCCESS:
    return statusTranslateSuccess(state, action.id, action.translation, action.domain, action.mode, action.translationRequestId, action.contentStatusId);
  case STATUS_TRANSLATE_FAIL:
    return statusTranslateFail(state, action.id, action.translationRequestId);
  case STATUS_TRANSLATE_SET_MODE:
    return statusTranslateSetMode(state, action.id, action.mode);
  case STATUS_TRANSLATE_UNDO:
    return statusTranslateUndo(state, action.id);
  case STATUS_TRANSLATION_ASSUMPTION:
    return statusTranslationAssumption(state, action.id);
  case STATUS_TRANSLATION_TARGET:
    return invalidateTranslationTarget(state);
  default:
    return state;
  }
};

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
} from '../actions/statuses';
import { TIMELINE_DELETE } from '../actions/timelines';
import { STATUS_IMPORT, STATUSES_IMPORT } from '../actions/importer';
import { normalizeStatusTranslation } from '../actions/importer/normalizer';
import { me } from '../initial_state';
import { Map as ImmutableMap, List, fromJS } from 'immutable';

const importStatus = (state, status) => {
  if (state.getIn([status.in_reply_to_id, 'replies_count'], null) === 0) {
    state = state.setIn([status.in_reply_to_id, 'replies_count'], 1);
  }
  return state.set(status.id, fromJS(status));
};

const importStatuses = (state, statuses) =>
  state.withMutations(mutable => statuses.forEach(status => importStatus(mutable, status)));

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

const statusTranslateRequest = (state, id) => {
  if (!state.get(id)) {
    return state;
  }

  return state.setIn([id, 'translationPending'], true);
};

const statusTranslateSuccess = (state, id, translation, domain, mode) => {
  if (!state.get(id)) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn([id, 'translation'], fromJS(normalizeStatusTranslation(translation, map.get(id), domain)));
    map.setIn([id, 'translationPending'], false);
    map.setIn([id, 'translationMode'], statusTranslationMode(mode));

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

const statusTranslateFail = (state, id) => {
  if (!state.get(id)) {
    return state;
  }

  return state.setIn([id, 'translationPending'], false);
};

const statusTranslateSetMode = (state, id, mode) => {
  if (!state.get(id) || !['original', 'translated', 'bilingual'].includes(mode)) {
    return state;
  }

  return state.setIn([id, 'translationMode'], mode);
};

const statusTranslateUndo = (state, id) => {
  if (!state.get(id)) {
    return state;
  }

  return state.withMutations(map => {
    map.deleteIn([id, 'translation']);
    map.deleteIn([id, 'translationMode']);
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
  case REBLOG_REQUEST:
    return state.setIn([action.status.get('id'), 'reblogged'], true);
  case REBLOG_FAIL:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'reblogged'], false);
  case UNREBLOG_REQUEST:
    return state.get(action.status.get('id')) === undefined ? state : state.setIn([action.status.get('id'), 'reblogged'], false);
  case UNREBLOG_FAIL:
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
    return statusTranslateRequest(state, action.id);
  case STATUS_TRANSLATE_SUCCESS:
    return statusTranslateSuccess(state, action.id, action.translation, action.domain, action.mode);
  case STATUS_TRANSLATE_FAIL:
    return statusTranslateFail(state, action.id);
  case STATUS_TRANSLATE_SET_MODE:
    return statusTranslateSetMode(state, action.id, action.mode);
  case STATUS_TRANSLATE_UNDO:
    return statusTranslateUndo(state, action.id);
  default:
    return state;
  }
};

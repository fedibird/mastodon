import {
  COMPOSE_MOUNT,
  COMPOSE_UNMOUNT,
  COMPOSE_CHANGE,
  COMPOSE_REPLY,
  COMPOSE_REPLY_CANCEL,
  COMPOSE_DIRECT,
  COMPOSE_QUOTE,
  COMPOSE_QUOTE_CANCEL,
  COMPOSE_MENTION,
  COMPOSE_SUBMIT_REQUEST,
  COMPOSE_SUBMIT_SUCCESS,
  COMPOSE_SUBMIT_FAIL,
  COMPOSE_UPLOAD_REQUEST,
  COMPOSE_UPLOAD_SUCCESS,
  COMPOSE_UPLOAD_FAIL,
  COMPOSE_UPLOAD_UNDO,
  COMPOSE_UPLOAD_PROGRESS,
  COMPOSE_UPLOAD_PROCESSING,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
  THUMBNAIL_UPLOAD_REQUEST,
  THUMBNAIL_UPLOAD_SUCCESS,
  THUMBNAIL_UPLOAD_FAIL,
  THUMBNAIL_UPLOAD_PROGRESS,
  COMPOSE_SUGGESTIONS_CLEAR,
  COMPOSE_SUGGESTIONS_READY,
  COMPOSE_SUGGESTION_SELECT,
  COMPOSE_SUGGESTION_TAGS_UPDATE,
  COMPOSE_TAG_HISTORY_UPDATE,
  COMPOSE_SENSITIVITY_CHANGE,
  COMPOSE_SPOILERNESS_CHANGE,
  COMPOSE_SPOILER_TEXT_CHANGE,
  COMPOSE_VISIBILITY_CHANGE,
  COMPOSE_LANGUAGE_CHANGE,
  COMPOSE_SEARCHABILITY_CHANGE,
  COMPOSE_CIRCLE_CHANGE,
  COMPOSE_COMPOSING_CHANGE,
  COMPOSE_EMOJI_INSERT,
  COMPOSE_UPLOAD_CHANGE_REQUEST,
  COMPOSE_UPLOAD_CHANGE_SUCCESS,
  COMPOSE_UPLOAD_CHANGE_FAIL,
  COMPOSE_RESET,
  COMPOSE_POLL_ADD,
  COMPOSE_POLL_REMOVE,
  COMPOSE_POLL_OPTION_ADD,
  COMPOSE_POLL_OPTION_CHANGE,
  COMPOSE_POLL_OPTION_REMOVE,
  COMPOSE_POLL_SETTINGS_CHANGE,
  INIT_MEDIA_EDIT_MODAL,
  COMPOSE_CHANGE_MEDIA_DESCRIPTION,
  COMPOSE_CHANGE_MEDIA_FOCUS,
  COMPOSE_MEDIA_ORDER_CHANGE,
  COMPOSE_SET_STATUS,
  COMPOSE_EDIT_CANCEL,
  COMPOSE_DATETIME_FORM_OPEN,
  COMPOSE_DATETIME_FORM_CLOSE,
  COMPOSE_SCHEDULED_CHANGE,
  COMPOSE_EXPIRES_CHANGE,
  COMPOSE_EXPIRES_ACTION_CHANGE,
  COMPOSE_REFERENCE_ADD,
  COMPOSE_REFERENCE_REMOVE,
  COMPOSE_REFERENCE_RESET,
  COMPOSE_REFERENCE_CHECK_IGNORE,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
} from '../actions/compose';
import { TIMELINE_DELETE, TIMELINE_EXPIRE } from '../actions/timelines';
import { REDRAFT } from '../actions/statuses';
import { COMPOSER_CONTEXT_APPLY, COMPOSER_CONTEXT_HASHTAG_TOGGLE, COMPOSER_SURFACE_ACCEPT } from '../actions/composer';
import { COMPOSER_SENDER_IDENTITY_SELECT, POSTING_IDENTITIES_FETCH_FAIL, POSTING_IDENTITIES_FETCH_SUCCESS } from '../actions/posting_identities';
import { USER_POSTING_STYLE_AUTO_ATTEMPT, USER_POSTING_STYLE_COMMIT, USER_POSTING_STYLE_DEFAULTS_SETTLED, USER_POSTING_STYLE_DESTINATION, USER_POSTING_STYLE_DESTINATION_RETRY, USER_POSTING_STYLE_HASHTAG_TOGGLE } from '../actions/user_posting_styles';
import { Map as ImmutableMap, List as ImmutableList, Set as ImmutableSet, OrderedSet as ImmutableOrderedSet, fromJS } from 'immutable';
import uuid from '../uuid';
import { normalizeManagedHashtagName } from '../posting_context/managed_hashtags';
import { managedMentionPlacement } from '../posting_context/managed_mentions';
import { isExistingPostEdit, postingContextOutputSignature } from '../posting_context/materialize';
import { styleMatchesSurface, surfaceApplyDecision } from '../posting_context/surface';
import { resolveUserPostingStyle } from '../posting_context/user_style_resolver';
import {
  abandonStyleDestination,
  applySensitiveOnFirstMedia,
  applySensitiveOnLastMediaRemoved,
  clearStyleManualState,
  beginStyleDestinationRetry,
  commitUserPostingStyle,
  finishStyleDestination,
  initialUserPostingStyle,
  notePortableDraftInput,
  reapplySelectedStyle,
  releaseStyleDestination,
  rememberManualSetting,
  syncSensitiveWithWarning,
  toggleStyleHashtag,
} from '../posting_context/user_style_state';
import { me } from '../initial_state';
import { initialSenderIdentity, localPostingIdentityId } from '../posting_identity/identity';
import { unescapeHTML } from '../utils/html';
import { format } from 'date-fns';

export const initialState = ImmutableMap({
  mounted: 0,
  sensitive: false,
  spoiler: false,
  spoiler_text: '',
  privacy: null,
  searchability: null,
  circle_id: null,
  id: null,
  language: null,
  text: '',
  focusDate: null,
  caretPosition: null,
  preselectDate: null,
  in_reply_to: null,
  quote_from: null,
  quote_from_url: null,
  reply_status: null,
  is_composing: false,
  is_submitting: false,
  is_changing_upload: false,
  is_uploading: false,
  dirty: false,
  progress: 0,
  isUploadingThumbnail: false,
  thumbnailProgress: 0,
  media_attachments: ImmutableList(),
  pending_media_attachments: 0,
  poll: null,
  poll_max_options: 4,
  suggestion_token: null,
  suggestions: ImmutableList(),
  default_privacy: 'public',
  default_sensitive: false,
  default_language: null,
  default_searchability: 'private',
  resetFileKey: Math.floor((Math.random() * 0x10000)),
  idempotencyKey: null,
  tagHistory: ImmutableList(),
  media_modal: ImmutableMap({
    id: null,
    description: '',
    focusX: 0,
    focusY: 0,
    dirty: false,
  }),
  datetime_form: null,
  default_expires: null,
  scheduled: null,
  expires: null,
  expires_action: 'mark',
  references: ImmutableSet(),
  context_references: ImmutableSet(),
  ignore_reference_check: false,
  prohibited_visibilities: ImmutableSet(),
  prohibited_words: ImmutableSet(),
  scheduled_status_id: null,
  draft_audience_account_id: null,
  posting_context_account_id: null,
  context: ImmutableMap({
    key: null,
    resolvedAccountId: null,
    source: null,
    managed: ImmutableMap({
      hashtags: ImmutableList(),
      mentions: ImmutableList(),
    }),
    suppressions: ImmutableMap({
      hashtags: ImmutableSet(),
    }),
    requirements: ImmutableMap({
      followingAccounts: ImmutableList(),
    }),
    constraints: ImmutableMap({
      allowedVisibilities: null,
    }),
    protocol: ImmutableMap({
      activityPub: ImmutableMap({
        audience: null,
      }),
    }),
  }),
  userPostingStyle: initialUserPostingStyle(),
  senderIdentity: initialSenderIdentity(me),
  surface: null,
  pendingSurface: null,
  displayedSurface: null,
  surfaceMismatch: false,
  surfaceEpoch: 0,
});

const initialPoll = ImmutableMap({
  options: ImmutableList(['', '']),
  expires_in: 24 * 3600,
  multiple: false,
});

const statusToTextMentions = (text, privacy, replyStatus) => {
  if(replyStatus === null) {
    return text;
  }

  let mentions = ImmutableOrderedSet();
  const replyStatusMentions = replyStatus.get('mentions').filterNot(mention => mention.get('id') === me);
  const groupMentions = replyStatusMentions.filter(   mention => mention.get('group'));
  const otherMentions = replyStatusMentions.filterNot(mention => mention.get('group'));

  mentions = mentions.union(groupMentions.map(mention => `@${mention.get('moved_acct') ?? mention.get('acct')} `));

  if (replyStatus.getIn(['account', 'id']) !== me) {
    mentions = mentions.add(`@${replyStatus.getIn(['account', 'moved_acct']) ?? replyStatus.getIn(['account', 'acct'])} `);
  }

  mentions = mentions.union(otherMentions.map(mention => `@${mention.get('moved_acct') ?? mention.get('acct')} `));

  const match = /^(\s*(?:(?:@\S+)\s*)*)([\s\S]*)/.exec(text);
  const extrctMentions = ImmutableOrderedSet(match[1].trim().split(/\s+/).filter(Boolean).map(mention => `${mention} `));
  const others = match[2];

  if(privacy === 'limited') {
    return extrctMentions.subtract(mentions).add(others).join('');
  } else {
    return mentions.union(extrctMentions).add(others).join('');
  }
};

const clearManagedHashtagSuppressions = map => {
  map.setIn(['context', 'suppressions', 'hashtags'], ImmutableSet());
};

const managedHashtagRecord = tag => {
  const name = String((tag && (tag.name || tag.normalizedName)) || '').replace(/^[#＃]+/u, '');

  return ImmutableMap({
    name,
    normalizedName: normalizeManagedHashtagName((tag && (tag.normalizedName || tag.name)) || ''),
    enforcement: (tag && tag.enforcement) || 'advisory',
    ruleId: (tag && tag.ruleId) || null,
  });
};

const managedMentionRecord = mention => ImmutableMap({
  accountId: mention ? mention.accountId : null,
  acct: mention && mention.acct ? String(mention.acct).replace(/^@+/u, '') : null,
  enforcement: (mention && mention.enforcement) || 'required',
  ruleId: (mention && mention.ruleId) || null,
  placement: managedMentionPlacement(mention),
});

const followingAccountRecord = requirement => ImmutableMap({
  accountId: requirement ? requirement.accountId : null,
  acct: requirement && requirement.acct ? String(requirement.acct).replace(/^@+/u, '') : null,
  enforcement: (requirement && requirement.enforcement) || 'required',
  ruleId: (requirement && requirement.ruleId) || null,
});

const allowedVisibilitySet = postingContext => {
  const allowed = postingContext.constraints && postingContext.constraints.allowedVisibilities;

  if (!allowed) {
    return null;
  }

  return ImmutableSet(allowed);
};

const activityPubAudienceRecord = audience => {
  if (!audience) {
    return null;
  }

  const accountId = audience.accountId === null || audience.accountId === undefined || audience.accountId === '' ? null : String(audience.accountId);

  return ImmutableMap({
    accountId,
    acct: audience.acct ? String(audience.acct).replace(/^@+/u, '') : null,
    enforcement: audience.enforcement || null,
    ruleId: audience.ruleId || null,
  });
};

const activityPubAudienceFromContext = postingContext => {
  const protocol = postingContext && postingContext.protocol;
  const activityPub = protocol && protocol.activityPub;

  return activityPub && activityPub.audience;
};

const retainedAudienceAccountId = value => (
  value === null || value === undefined || value === '' ? null : value
);

const emptyProtocol = () => ImmutableMap({
  activityPub: ImmutableMap({
    audience: null,
  }),
});

const emptyPostingContext = () => ImmutableMap({
  key: null,
  resolvedAccountId: null,
  source: null,
  managed: ImmutableMap({
    hashtags: ImmutableList(),
    mentions: ImmutableList(),
  }),
  suppressions: ImmutableMap({
    hashtags: ImmutableSet(),
  }),
  requirements: ImmutableMap({
    followingAccounts: ImmutableList(),
  }),
  constraints: ImmutableMap({
    allowedVisibilities: null,
  }),
  protocol: emptyProtocol(),
});

const clearScheduledDraftProvenance = map => {
  map.set('scheduled_status_id', null);
  map.set('draft_audience_account_id', null);
};

const clearAll = state => {
  return state.withMutations(map => {
    map.set('id', null);
    map.set('language', state.get('default_language'));
    map.set('text', '');
    map.set('spoiler', false);
    map.set('spoiler_text', '');
    map.set('is_submitting', false);
    map.set('is_changing_upload', false);
    map.set('in_reply_to', null);
    map.set('quote_from', null);
    map.set('reply_status', null);
    map.set('privacy', state.get('default_privacy'));
    map.set('searchability', state.get('default_searchability'));
    map.set('circle_id', null);
    map.set('sensitive', false);
    map.update('media_attachments', list => list.clear());
    map.set('poll', null);
    map.set('idempotencyKey', uuid());
    map.set('dirty', false);
    map.set('datetime_form', null);
    map.set('default_expires', state.get('default_expires_in') ? true : null);
    map.set('scheduled', null);
    map.set('expires', state.get('default_expires_in', null));
    map.set('expires_action', state.get('default_expires_action', 'mark'));
    map.update('references', set => set.clear());
    map.update('context_references', set => set.clear());
    map.set('ignore_reference_check', false);
    clearScheduledDraftProvenance(map);
    clearManagedHashtagSuppressions(map);
  });
};

const appendMedia = (state, media, file) => {
  const prevSize = state.get('media_attachments').size;

  return state.withMutations(map => {
    if (media.get('type') === 'image') {
      media = media.set('file', file);
    }
    map.update('media_attachments', list => list.push(media.set('unattached', media.get('unattached', true))).sortBy(item => item.get('order')));
    map.set('is_uploading', false);
    map.set('is_processing', false);
    map.set('resetFileKey', Math.floor((Math.random() * 0x10000)));
    map.set('idempotencyKey', uuid());
    map.update('pending_media_attachments', n => n - 1);

    if (prevSize === 0) {
      applySensitiveOnFirstMedia(map, state);
    }

    notePortableDraftInput(map);
  });
};

const removeMedia = (state, mediaId) => {
  const prevSize = state.get('media_attachments').size;

  return state.withMutations(map => {
    map.update('media_attachments', list => list.filterNot(item => item.get('id') === mediaId));
    map.set('idempotencyKey', uuid());

    if (prevSize === 1) {
      applySensitiveOnLastMediaRemoved(map, state);
    }
  });
};

const insertSuggestion = (state, position, token, completion, path) => {
  return state.withMutations(map => {
    map.updateIn(path, oldText => `${oldText.slice(0, position)}${completion} ${oldText.slice(position + token.length)}`);
    map.set('suggestion_token', null);
    map.set('suggestions', ImmutableList());
    if (path.length === 1 && path[0] === 'text') {
      map.set('focusDate', new Date());
      map.set('caretPosition', position + completion.length + 1);
    }
    map.set('idempotencyKey', uuid());
  });
};

const sortHashtagsByUse = (state, tags) => {
  const personalHistory = state.get('tagHistory').map(tag => tag.toLowerCase());

  const tagsWithLowercase = tags.map(t => ({ ...t, lowerName: t.name.toLowerCase() }));
  const sorted = tagsWithLowercase.sort((a, b) => {
    const usedA = personalHistory.includes(a.lowerName);
    const usedB = personalHistory.includes(b.lowerName);

    if (usedA === usedB) {
      return 0;
    } else if (usedA && !usedB) {
      return -1;
    } else {
      return 1;
    }
  });
  sorted.forEach(tag => delete tag.lowerName);
  return sorted;
};

const insertEmoji = (state, position, emojiData, needsSpace) => {
  const oldText = state.get('text');
  const emoji = needsSpace ? ' ' + emojiData.native : emojiData.native;

  return state.merge({
    text: `${oldText.slice(0, position)}${emoji} ${oldText.slice(position)}`,
    focusDate: new Date(),
    caretPosition: position + emoji.length + 1,
    idempotencyKey: uuid(),
  });
};

const privacyExpand = (a, b) => {
  const order = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
  return order[Math.min(order.indexOf(a), order.indexOf(b), order.length - 1)];
};

const privacyCap = (a, b) => {
  const order = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
  return order[Math.max(order.indexOf(a), order.indexOf(b), 0)];
};

const searchabilityCap = (a, b) => {
  const order = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
  const to    = ['public', 'private',  'private', 'direct', 'direct',  'direct', 'direct'];
  return to[Math.max(order.indexOf(a), order.indexOf(b), 0)];
};

export const hydrateComposer = (state, hydratedState) => {
  state = clearAll(state.merge(hydratedState));

  if (hydratedState.has('text')) {
    state = state.set('text', hydratedState.get('text'));
  }

  if (hydratedState.has('prohibited_visibilities')) {
    state = state.set('prohibited_visibilities', hydratedState.get('prohibited_visibilities').toSet());
  }

  if (hydratedState.has('prohibited_words')) {
    state = state.set('prohibited_words', hydratedState.get('prohibited_words').toSet());
  }

  return state.set('senderIdentity', initialSenderIdentity(me));
};

const domParser = new DOMParser();

const expandMentions = status => {
  const fragment = domParser.parseFromString(status.get('content', ''), 'text/html').documentElement;

  status.get('mentions', ImmutableList()).forEach(mention => {
    fragment.querySelector(`a[href="${mention.get('url')}"]`).textContent = `@${mention.get('acct')}`;
  });

  return fragment.innerHTML;
};

const expiresInFromExpiresAt = expires_at => {
  if (!expires_at) return 24 * 3600;
  const delta = (new Date(expires_at).getTime() - Date.now()) / 1000;
  return [300, 1800, 3600, 21600, 86400, 259200, 604800].find(expires_in => expires_in >= delta) || 24 * 3600;
};

const mergeLocalHashtagResults = (suggestions, prefix, tagHistory) => {
  prefix = prefix.toLowerCase();
  if (suggestions.length < 4) {
    const localTags = tagHistory.filter(tag => tag.toLowerCase().startsWith(prefix) && !suggestions.some(suggestion => suggestion.type === 'hashtag' && suggestion.name.toLowerCase() === tag.toLowerCase()));
    return suggestions.concat(localTags.slice(0, 4 - suggestions.length).toJS().map(tag => ({ type: 'hashtag', name: tag })));
  } else {
    return suggestions;
  }
};

const normalizeSuggestions = (state, { accounts, emojis, tags, token }) => {
  if (accounts) {
    return accounts.map(item => ({ id: item.id, type: 'account' }));
  } else if (emojis) {
    return emojis.map(item => ({ ...item, type: 'emoji' }));
  } else {
    return mergeLocalHashtagResults(sortHashtagsByUse(state, tags.map(item => ({ ...item, type: 'hashtag' }))), token.slice(1), state.get('tagHistory'));
  }
};

const updateSuggestionTags = (state, token) => {
  const prefix = token.slice(1);

  const suggestions = state.get('suggestions').toJS();
  return state.merge({
    suggestions: ImmutableList(mergeLocalHashtagResults(suggestions, prefix, state.get('tagHistory'))),
    suggestion_token: token,
  });
};

const stripCompatibleText = html => {
  const fragment = domParser.parseFromString(html, 'text/html').documentElement;

  const original_media_link = fragment.querySelector('span.original-media-link');
  if (original_media_link) {
    original_media_link.remove();
  }

  const quote_inline = fragment.querySelector('span.quote-inline');
  if (quote_inline) {
    quote_inline.remove();
  }

  return fragment.innerHTML;
};

const rememberDisplayedSurface = (map, incoming, epoch) => {
  map.set('displayedSurface', ImmutableMap({
    kind: incoming.kind,
    key: incoming.key,
    surfaceEpoch: epoch,
  }));
};

const rememberSurface = (map, incoming, epoch) => {
  map.set('surface', ImmutableMap({ kind: incoming.kind, key: incoming.key }));
  map.set('pendingSurface', null);
  map.set('surfaceMismatch', false);
  map.set('surfaceEpoch', epoch);
  map.setIn(['userPostingStyle', 'destinationPolicy'], 'locked');
  rememberDisplayedSurface(map, incoming, epoch);
};

const rememberPendingSurface = (map, action, incoming) => {
  const epoch = action.surfaceEpoch || map.get('surfaceEpoch') || 0;

  map.set('surfaceMismatch', true);
  map.set('surfaceEpoch', epoch);
  map.set('pendingSurface', ImmutableMap({
    kind: incoming.kind,
    key: incoming.key,
    postingContext: action.postingContext,
    postingContextAccountId: action.postingContextAccountId ?? null,
    hasPostingContext: action.hasPostingContext !== false,
    surfaceEpoch: action.surfaceEpoch || 0,
  }));
  rememberDisplayedSurface(map, incoming, epoch);
};

const releaseIncompatibleStyle = (state, incoming) => {
  const selectedId = state.getIn(['userPostingStyle', 'selectedId']);
  const snapshot = state.getIn(['userPostingStyle', 'snapshot']);

  if (!selectedId || styleMatchesSurface(snapshot, incoming)) {
    return state;
  }

  return commitUserPostingStyle(state, {
    plan: resolveUserPostingStyle(null, state, { destinationPolicy: 'locked' }),
    snapshot: null,
    resetSuppressions: true,
    selectionOrigin: null,
    evaluatedSurface: null,
  });
};

const applyPostingContextFields = (state, action) => {
  const postingContext = action.postingContext;
  const hasPostingContextAccountId = Object.prototype.hasOwnProperty.call(action, 'postingContextAccountId');
  const postingContextAccountId = hasPostingContextAccountId ? (action.postingContextAccountId || null) : null;
  const previousSignature = postingContextOutputSignature(state);

  if (!postingContext) {
    return state.withMutations(map => {
      map.set('context', emptyPostingContext());

      if (hasPostingContextAccountId) {
        map.set('posting_context_account_id', postingContextAccountId);
      }

      if (previousSignature !== '' && (state.get('idempotencyKey') || state.get('text') || state.get('dirty'))) {
        map.set('idempotencyKey', uuid());
      }
    });
  }

  const nextKey = postingContext.key || null;
  const sameKey = state.getIn(['context', 'key']) === nextKey;
  const hashtags = ImmutableList(((postingContext.managed && postingContext.managed.hashtags) || []).map(managedHashtagRecord));
  const mentions = ImmutableList(((postingContext.managed && postingContext.managed.mentions) || []).map(managedMentionRecord));
  const followingAccounts = ImmutableList(((postingContext.requirements && postingContext.requirements.followingAccounts) || []).map(followingAccountRecord));
  const source = postingContext.source ? ImmutableMap({
    id: postingContext.source.id,
    revision: postingContext.source.revision,
  }) : null;

  return state.withMutations(map => {
    map.setIn(['context', 'key'], nextKey);
    map.setIn(['context', 'source'], source);

    if (hasPostingContextAccountId) {
      map.set('posting_context_account_id', postingContextAccountId);
      map.setIn(['context', 'resolvedAccountId'], postingContextAccountId);
    }
    map.setIn(['context', 'managed', 'hashtags'], hashtags);
    map.setIn(['context', 'managed', 'mentions'], mentions);
    map.setIn(['context', 'requirements', 'followingAccounts'], followingAccounts);
    map.setIn(['context', 'constraints', 'allowedVisibilities'], allowedVisibilitySet(postingContext));
    map.setIn(['context', 'protocol', 'activityPub', 'audience'], activityPubAudienceRecord(activityPubAudienceFromContext(postingContext)));

    if (!sameKey) {
      map.setIn(['context', 'suppressions', 'hashtags'], ImmutableSet());
    }

    if (previousSignature !== postingContextOutputSignature(map) && (state.get('idempotencyKey') || state.get('text') || state.get('dirty'))) {
      map.set('idempotencyKey', uuid());
    }
  });
};

const reduceSurfaceContext = (state, action) => {
  if (isExistingPostEdit(state)) {
    return state;
  }

  const decision = surfaceApplyDecision(state, action);

  if (decision.mode === 'ignore') {
    return state;
  }

  if (decision.mode === 'legacy') {
    return applyPostingContextFields(state, action);
  }

  if (decision.mode === 'mismatch' || decision.mode === 'refresh-pending') {
    return state.withMutations(map => rememberPendingSurface(map, action, decision.incoming));
  }

  if (decision.mode === 'release-held') {
    return state.withMutations(map => {
      rememberSurface(map, decision.incoming, action.surfaceEpoch || 0);
    });
  }

  if (decision.mode === 'surface-only') {
    const released = decision.shift ? releaseIncompatibleStyle(state, decision.incoming) : state;
    const previousSignature = postingContextOutputSignature(released);

    return released.withMutations(map => {
      if (decision.shift) {
        map.set('context', emptyPostingContext());
        map.set('posting_context_account_id', null);
      }

      rememberSurface(map, decision.incoming, action.surfaceEpoch || 0);
      map.setIn(['userPostingStyle', 'autoAttemptKey'], null);

      // A Group surface is a delivery target even before its definition arrives.
      if (decision.incoming.kind === 'group' && action.hasPostingContext === false) {
        map.set('posting_context_account_id', decision.incoming.key);
      }

      if (decision.accept) {
        map.setIn(['userPostingStyle', 'styleInputLock'], true);
      } else if (decision.shift) {
        map.setIn(['userPostingStyle', 'styleInputLock'], false);
      }

      if (decision.shift && !map.getIn(['userPostingStyle', 'selectedId'])) {
        map.setIn(['userPostingStyle', 'selectionOrigin'], null);
        map.setIn(['userPostingStyle', 'evaluatedSurface'], null);
      }

      if (decision.shift && previousSignature !== postingContextOutputSignature(map) && (released.get('idempotencyKey') || released.get('text') || released.get('dirty'))) {
        map.set('idempotencyKey', uuid());
      }
    });
  }

  const basis = decision.mode === 'replace' ? releaseIncompatibleStyle(state, decision.incoming) : state;
  const next = applyPostingContextFields(basis, action);

  return next.withMutations(map => {
    rememberSurface(map, decision.incoming, action.surfaceEpoch || 0);

    if (decision.mode !== 'replace') {
      return;
    }

    map.setIn(['userPostingStyle', 'autoAttemptKey'], null);

    if (!decision.accept) {
      map.setIn(['userPostingStyle', 'styleInputLock'], false);
    }

    if (!map.getIn(['userPostingStyle', 'selectedId'])) {
      map.setIn(['userPostingStyle', 'selectionOrigin'], null);
      map.setIn(['userPostingStyle', 'evaluatedSurface'], null);
    } else {
      map.setIn(['userPostingStyle', 'evaluatedSurface'], ImmutableMap({
        kind: decision.incoming.kind,
        key: decision.incoming.key,
      }));
    }

    if (decision.accept) {
      map.setIn(['userPostingStyle', 'styleInputLock'], true);
    }
  });
};

const senderIdentityList = identities => {
  if (!identities) {
    return ImmutableList();
  }

  if (ImmutableList.isList(identities)) {
    return identities;
  }

  return ImmutableList(identities);
};

const confirmedSenderStatus = (match, sessionId) => {
  if (!match || !sessionId || match.get('id') !== sessionId) {
    return 'unresolved';
  }

  const granted = (
    String(match.getIn(['account', 'id'])) === String(me) &&
    match.get('authorization') === 'ready' &&
    match.getIn(['capabilities', 'post']) === 'supported'
  );

  if (granted) {
    return 'ready';
  }

  return match.get('authorization') || 'unresolved';
};

const confirmSenderIdentity = (state, identities) => {
  const sender = state.get('senderIdentity') || initialSenderIdentity(me);
  const sessionId = localPostingIdentityId(me);
  const id = sender.get('id') || sessionId;
  const match = senderIdentityList(identities).find(identity => identity.get && identity.get('id') === id);

  return state.set('senderIdentity', sender.merge({
    id: sessionId || id,
    selectionOrigin: sender.get('selectionOrigin') || 'default',
    status: confirmedSenderStatus(match, sessionId),
    changeEpoch: sender.get('changeEpoch') || 0,
  }));
};

export default function composer(state = initialState, action) {
  switch(action.type) {
  case COMPOSE_MOUNT:
    return state.set('mounted', state.get('mounted') + 1);
  case POSTING_IDENTITIES_FETCH_SUCCESS:
    return confirmSenderIdentity(state, action.identities);
  case POSTING_IDENTITIES_FETCH_FAIL:
    return state.set('senderIdentity', (state.get('senderIdentity') || initialSenderIdentity(me)).set('status', 'unresolved'));
  case COMPOSER_SENDER_IDENTITY_SELECT: {
    const sessionId = localPostingIdentityId(me);
    const sender = state.get('senderIdentity') || initialSenderIdentity(me);

    if (!sessionId || action.identityId !== sessionId || sender.get('status') !== 'ready') {
      return state;
    }

    if (sender.get('id') === sessionId && sender.get('selectionOrigin') === 'selected') {
      return state;
    }

    return state.set('senderIdentity', sender.merge({
      id: sessionId,
      selectionOrigin: 'selected',
      status: 'ready',
      changeEpoch: sender.get('changeEpoch') || 0,
    }));
  }
  case COMPOSE_UNMOUNT:
    return state
      .set('mounted', Math.max(state.get('mounted') - 1, 0))
      .set('is_composing', false);
  case COMPOSER_CONTEXT_APPLY:
    return reduceSurfaceContext(state, action);
  case COMPOSER_SURFACE_ACCEPT: {
    const pending = state.get('pendingSurface');
    const displayed = state.get('displayedSurface');

    if (!pending || !state.get('surfaceMismatch') || !displayed) {
      return state;
    }

    if (displayed.get('kind') !== pending.get('kind') || String(displayed.get('key')) !== String(pending.get('key'))) {
      return state;
    }

    return reduceSurfaceContext(state, {
      type: COMPOSER_CONTEXT_APPLY,
      postingContext: pending.get('postingContext'),
      postingContextAccountId: pending.get('postingContextAccountId'),
      hasPostingContext: pending.get('hasPostingContext') !== false,
      surface: { kind: pending.get('kind'), key: pending.get('key') },
      surfaceEpoch: Math.max(Number(state.get('surfaceEpoch')) || 0, Number(pending.get('surfaceEpoch')) || 0),
      forceSurface: true,
    });
  }
  case USER_POSTING_STYLE_AUTO_ATTEMPT:
    return state.setIn(['userPostingStyle', 'autoAttemptKey'], action.autoAttemptKey);
  case USER_POSTING_STYLE_DEFAULTS_SETTLED:
    return state.setIn(['userPostingStyle', 'defaultsSettledSurface'], action.surfaceKey || null);
  case USER_POSTING_STYLE_COMMIT:
    return commitUserPostingStyle(state, action);
  case USER_POSTING_STYLE_DESTINATION:
    return finishStyleDestination(state, action);
  case USER_POSTING_STYLE_DESTINATION_RETRY:
    return beginStyleDestinationRetry(state);
  case USER_POSTING_STYLE_HASHTAG_TOGGLE:
    return toggleStyleHashtag(state, action);
  case COMPOSER_CONTEXT_HASHTAG_TOGGLE: {
    if (isExistingPostEdit(state)) {
      return state;
    }

    const normalizedName = normalizeManagedHashtagName(action.normalizedName);
    const suppressed = state.getIn(['context', 'suppressions', 'hashtags'], ImmutableSet());
    const next = suppressed.includes(normalizedName) ? suppressed.delete(normalizedName) : suppressed.add(normalizedName);

    return state
      .setIn(['context', 'suppressions', 'hashtags'], next)
      .set('dirty', true)
      .set('idempotencyKey', uuid());
  }
  case COMPOSE_SENSITIVITY_CHANGE:
    return state.withMutations(map => {
      if (!state.get('spoiler')) {
        map.set('sensitive', !state.get('sensitive'));
        rememberManualSetting(map, 'sensitive');
      }

      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
    });
  case COMPOSE_SPOILERNESS_CHANGE:
    return state.withMutations(map => {
      const nextSpoiler = !state.get('spoiler');

      map.set('spoiler', nextSpoiler);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
      const handled = syncSensitiveWithWarning(map, state, {
        spoiler: nextSpoiler,
        spoilerText: state.get('spoiler_text'),
      });

      if (!handled && nextSpoiler && !state.get('sensitive') && state.get('media_attachments').size >= 1) {
        map.set('sensitive', true);
      }

      rememberManualSetting(map, 'spoiler');
    });
  case COMPOSE_SPOILER_TEXT_CHANGE:
    if (!state.get('spoiler')) return state;
    return state.withMutations(map => {
      map.set('spoiler_text', action.text);
      syncSensitiveWithWarning(map, state, {
        spoiler: true,
        spoilerText: action.text,
      });
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
      rememberManualSetting(map, 'spoiler');
    });
  case COMPOSE_VISIBILITY_CHANGE:
    if (state.get('id')) return state;
    return state.withMutations(map => {
      const searchability = searchabilityCap(action.value, state.get('searchability'));

      map.set('text', statusToTextMentions(state.get('text'), action.value, state.get('reply_status')));
      map.set('privacy', action.value);
      map.set('searchability', searchability);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
      map.set('circle_id', null);
      rememberManualSetting(map, 'privacy');
    });
  case COMPOSE_SEARCHABILITY_CHANGE:
    if (state.get('id')) return state;
    return state.withMutations(map => {
      map.set('searchability', action.value);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);

      const privacy = privacyExpand(action.value, state.get('privacy'));

      if (privacy !== state.get('privacy')) {
        map.set('text', statusToTextMentions(state.get('text'), action.value, state.get('reply_status')));
        map.set('privacy', privacy);
        map.set('circle_id', null);
      }
    });
  case COMPOSE_CIRCLE_CHANGE:
    if (state.get('id')) return state;
    return state
      .set('circle_id', action.value)
      .set('idempotencyKey', uuid())
      .set('dirty', true);
  case COMPOSE_CHANGE:
    return state.withMutations(map => {
      map.set('text', action.text);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);

      if (String(action.text || '').trim()) {
        notePortableDraftInput(map);
      }
    });
  case COMPOSE_COMPOSING_CHANGE:
    return state.set('is_composing', action.value);
  case COMPOSE_REPLY:
    return state.withMutations(map => {
      releaseStyleDestination(map);

      if (state.get('id')) {
        map.update('media_attachments', list => list.clear());
        map.set('poll', null);
      }

      map.set('id', null);

      if (action.status.get('language') && !action.status.has('translation')) {
        map.set('language', action.status.get('language'));
      } else {
        map.set('language', state.get('default_language'));
      }

      const privacy = privacyCap(action.status.get('visibility'), state.get('default_privacy'));
      const searchability = searchabilityCap(action.status.get('visibility'), state.get('default_searchability'));

      map.set('in_reply_to', action.status.get('id'));
      map.set('quote_from', null);
      map.set('quote_from_url', null);
      map.set('reply_status', action.status);
      map.set('text', statusToTextMentions('', privacy, action.status));
      clearManagedHashtagSuppressions(map);
      map.set('privacy', privacy);
      map.set('searchability', searchability);
      map.set('circle_id', null);
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('preselectDate', new Date());
      map.set('idempotencyKey', uuid());
      map.set('dirty', false);
      map.set('datetime_form', null);
      map.set('default_expires', state.get('default_expires_in') ? true : null);
      map.set('scheduled', null);
      map.set('expires', state.get('default_expires_in', null));
      map.set('expires_action', state.get('default_expires_action', 'mark'));
      map.update('context_references', set => set.clear().concat(action.context_references));
      clearScheduledDraftProvenance(map);

      if (action.status.get('spoiler_text').length > 0) {
        map.set('spoiler', true);
        map.set('spoiler_text', action.status.get('spoiler_text'));
      } else {
        map.set('spoiler', false);
        map.set('spoiler_text', '');
      }
    });
  case COMPOSE_QUOTE:
    return state.withMutations(map => {
      releaseStyleDestination(map);

      if (state.get('id')) {
        map.update('media_attachments', list => list.clear());
        map.set('poll', null);
      }

      map.set('id', null);
      map.set('language', state.get('default_language'));

      const privacy = privacyCap(action.status.get('visibility'), state.get('default_privacy'));
      const searchability = searchabilityCap(action.status.get('visibility'), state.get('default_searchability'));

      map.set('in_reply_to', null);
      map.set('quote_from', action.status.get('id'));
      map.set('quote_from_url', action.status.get('url'));
      map.set('text', '');
      clearManagedHashtagSuppressions(map);
      map.set('privacy', privacy);
      map.set('searchability', searchability);
      map.set('focusDate', new Date());
      map.set('preselectDate', new Date());
      map.set('idempotencyKey', uuid());
      map.set('dirty', false);
      map.set('datetime_form', null);
      map.set('default_expires', state.get('default_expires_in') ? true : null);
      map.set('scheduled', null);
      map.set('expires', state.get('default_expires_in', null));
      map.set('expires_action', state.get('default_expires_action', 'mark'));
      map.update('context_references', set => set.clear().add(action.status.get('id')));
      clearScheduledDraftProvenance(map);

      if (action.status.get('spoiler_text').length > 0) {
        map.set('spoiler', true);
        map.set('spoiler_text', action.status.get('spoiler_text'));
      } else {
        map.set('spoiler', false);
        map.set('spoiler_text', '');
      }
    });
  case COMPOSE_EDIT_CANCEL:
    return reapplySelectedStyle(clearStyleManualState(clearAll(state)), { respectManual: false, resetSuppressions: true });
  case COMPOSE_REPLY_CANCEL:
  case COMPOSE_QUOTE_CANCEL:
  case COMPOSE_SCHEDULED_EDIT_CANCEL:
  case COMPOSE_RESET:
    if (state.get('id')) {
      return reapplySelectedStyle(clearStyleManualState(clearAll(state)), { respectManual: false, resetSuppressions: true });
    }

    return reapplySelectedStyle(state.withMutations(map => {
      map.set('in_reply_to', null);
      map.set('quote_from', null);
      map.set('quote_from_url', null);
      map.set('reply_status', null);
      map.set('text', '');
      map.set('spoiler', false);
      map.set('spoiler_text', '');
      map.set('privacy', state.get('default_privacy'));
      map.set('searchability', state.get('default_searchability'));
      map.set('language', state.get('default_language'));
      map.set('circle_id', null);
      map.set('poll', null);
      map.set('idempotencyKey', uuid());
      map.set('dirty', false);
      map.set('datetime_form', null);
      map.set('default_expires', state.get('default_expires_in') ? true : null);
      map.set('scheduled', null);
      map.set('expires', state.get('default_expires_in', null));
      map.set('expires_action', state.get('default_expires_action', 'mark'));
      map.update('context_references', set => set.clear());
      if (action.type === COMPOSE_RESET || action.type === COMPOSE_SCHEDULED_EDIT_CANCEL) {
        map.update('references', set => set.clear());
      }
      clearScheduledDraftProvenance(map);
      clearManagedHashtagSuppressions(map);
    }), { respectManual: true, resetSuppressions: false });
  case COMPOSE_SUBMIT_REQUEST:
    return state.set('is_submitting', true);
  case COMPOSE_UPLOAD_CHANGE_REQUEST:
    return state.set('is_changing_upload', true);
  case COMPOSE_SUBMIT_SUCCESS:
  case SCHEDULED_STATUS_SUBMIT_SUCCESS:
    return reapplySelectedStyle(clearStyleManualState(clearAll(state)).withMutations(map => {
      map.setIn(['userPostingStyle', 'styleInputLock'], false);
      map.setIn(['userPostingStyle', 'autoAttemptKey'], null);
    }), { respectManual: false, resetSuppressions: true });
  case COMPOSE_SUBMIT_FAIL:
    return state.set('is_submitting', false);
  case COMPOSE_UPLOAD_CHANGE_FAIL:
    return state.set('is_changing_upload', false);
  case COMPOSE_UPLOAD_REQUEST:
    return state.set('is_uploading', true).update('pending_media_attachments', n => n + 1);
  case COMPOSE_UPLOAD_PROCESSING:
    return state.set('is_processing', true);
  case COMPOSE_UPLOAD_SUCCESS:
    return appendMedia(state, fromJS(action.media), action.file);
  case COMPOSE_UPLOAD_FAIL:
    return state.set('is_uploading', false).set('is_processing', false).update('pending_media_attachments', n => n - 1);
  case COMPOSE_UPLOAD_UNDO:
    return removeMedia(state, action.media_id);
  case COMPOSE_UPLOAD_PROGRESS:
    return state.set('progress', Math.round((action.loaded / action.total) * 100));
  case THUMBNAIL_UPLOAD_REQUEST:
    return state.set('isUploadingThumbnail', true);
  case THUMBNAIL_UPLOAD_PROGRESS:
    return state.set('thumbnailProgress', Math.round((action.loaded / action.total) * 100));
  case THUMBNAIL_UPLOAD_FAIL:
    return state.set('isUploadingThumbnail', false);
  case THUMBNAIL_UPLOAD_SUCCESS:
    return state
      .set('isUploadingThumbnail', false)
      .update('media_attachments', list => list.map(item => {
        if (item.get('id') === action.media.id) {
          return fromJS(action.media);
        }

        return item;
      }));
  case INIT_MEDIA_EDIT_MODAL:
    const media =  state.get('media_attachments').find(item => item.get('id') === action.id);
    return state.set('media_modal', ImmutableMap({
      id: action.id,
      description: media.get('description') || '',
      focusX: media.getIn(['meta', 'focus', 'x'], 0),
      focusY: media.getIn(['meta', 'focus', 'y'], 0),
      dirty: false,
    }));
  case COMPOSE_CHANGE_MEDIA_DESCRIPTION:
    return state.setIn(['media_modal', 'description'], action.description).setIn(['media_modal', 'dirty'], true);
  case COMPOSE_CHANGE_MEDIA_FOCUS:
    return state.setIn(['media_modal', 'focusX'], action.focusX).setIn(['media_modal', 'focusY'], action.focusY).setIn(['media_modal', 'dirty'], true);
  case COMPOSE_MENTION:
    return state.withMutations(map => {
      map.update('text', text => [text.trim(), `@${action.account.get('acct')} `].filter((str) => str.length !== 0).join(' '));
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('idempotencyKey', uuid());

      if (state.get('id')) {
        map.set('dirty', true);
      } else {
        clearScheduledDraftProvenance(map);
        map.set('dirty', false);
      }
    });
  case COMPOSE_DIRECT:
    return state.withMutations(map => {
      map.update('text', text => [text.trim(), `@${action.account.get('acct')} `].filter((str) => str.length !== 0).join(' '));
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('idempotencyKey', uuid());

      if (state.get('id')) {
        map.set('dirty', true);
        return;
      }

      map.set('privacy', 'direct');
      map.set('searchability', 'direct');
      map.set('circle_id', null);
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('idempotencyKey', uuid());
      clearScheduledDraftProvenance(map);
      map.set('dirty', false);
    });
  case COMPOSE_SUGGESTIONS_CLEAR:
    return state.update('suggestions', ImmutableList(), list => list.clear()).set('suggestion_token', null);
  case COMPOSE_SUGGESTIONS_READY:
    return state.set('suggestions', ImmutableList(normalizeSuggestions(state, action))).set('suggestion_token', action.token);
  case COMPOSE_SUGGESTION_SELECT:
    return insertSuggestion(state, action.position, action.token, action.completion, action.path);
  case COMPOSE_SUGGESTION_TAGS_UPDATE:
    return updateSuggestionTags(state, action.token);
  case COMPOSE_TAG_HISTORY_UPDATE:
    return state.set('tagHistory', fromJS(action.tags));
  case TIMELINE_DELETE:
  case TIMELINE_EXPIRE:
    if (action.id === state.get('in_reply_to')) {
      return state.set('in_reply_to', null);
    } else {
      return state;
    }
  case COMPOSE_EMOJI_INSERT:
    return insertEmoji(state, action.position, action.emoji, action.needsSpace);
  case COMPOSE_UPLOAD_CHANGE_SUCCESS:
    return state
      .set('is_changing_upload', false)
      .setIn(['media_modal', 'dirty'], false)
      .set('dirty', action.attached ? true : state.get('dirty'))
      .update('media_attachments', list => list.map(item => {
        if (item.get('id') === action.media.id) {
          const next = fromJS(action.media);

          return next
            .set('unattached', action.attached ? false : item.get('unattached', true))
            .set('order', item.has('order') ? item.get('order') : next.get('order'));
        }

        return item;
      }));
  case REDRAFT: {
    const scheduledStatusId = action.status.get('scheduled_status_id', null);

    return state.withMutations(map => {
      abandonStyleDestination(map);
      map.set('id', null);
      map.set('language', action.status.get('language') || state.get('default_language'));

      const datetime_form = !!action.status.get('scheduled_at') || !!action.status.get('expires_at') ? true : null;

      map.set('text', action.raw_text || unescapeHTML(stripCompatibleText(expandMentions(action.status))));
      clearManagedHashtagSuppressions(map);
      map.set('in_reply_to', action.status.get('in_reply_to_id', null));
      map.set('quote_from', action.status.getIn(['quote', 'id'], null));
      map.set('quote_from_url', action.status.getIn(['quote', 'url']));
      map.set('reply_status', action.replyStatus);
      map.set('privacy', action.status.get('visibility', state.get('default_privacy')));
      map.set('searchability', action.status.get('searchability', state.get('default_searchability')));
      map.set('circle_id', action.status.get('circle_id', null));
      map.set('media_attachments', action.status.get('media_attachments', ImmutableList()));
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
      map.set('poll', action.status.get('poll', null));
      map.set('sensitive', action.status.get('sensitive', false));
      map.set('datetime_form', datetime_form);
      map.set('default_expires', !datetime_form && state.get('default_expires_in') ? true : null);
      map.set('scheduled', action.status.get('scheduled_at') ? format(new Date(action.status.get('scheduled_at')), 'yyyy-MM-dd HH:mm') : null);
      map.set('expires', action.status.get('expires_at') ? format(new Date(action.status.get('expires_at')), 'yyyy-MM-dd HH:mm') : state.get('default_expires_in', null));
      map.set('expires_action', action.status.get('expires_action') ?? state.get('default_expires_action', 'mark'));
      map.update('references', set => set.clear().concat(action.status.get('status_reference_ids', ImmutableList())).delete(action.status.getIn(['quote', 'id'], ImmutableList())));
      map.update('context_references', set => set.clear().concat(action.context_references));
      map.set('ignore_reference_check', true);
      map.set('scheduled_status_id', scheduledStatusId);
      map.set('draft_audience_account_id', scheduledStatusId ? retainedAudienceAccountId(action.status.get('audience_account_id', null)) : null);

      if (action.status.get('spoiler_text', '').length > 0) {
        map.set('spoiler', true);
        map.set('spoiler_text', action.status.get('spoiler_text'));
      } else {
        map.set('spoiler', false);
        map.set('spoiler_text', '');
      }

      if (action.status.get('poll')) {
        map.set('poll', ImmutableMap({
          options: action.status.getIn(['poll', 'options']).map(x => typeof x === 'string' ? x : x.get('title')),
          multiple: action.status.getIn(['poll', 'multiple']),
          expires_in: expiresInFromExpiresAt(action.status.getIn(['poll', 'expires_at'])),
        }));
      }
    });
  }
  case COMPOSE_POLL_ADD:
    return state.withMutations(map => {
      map.set('poll', initialPoll);
      notePortableDraftInput(map);
    });
  case COMPOSE_POLL_REMOVE:
    return state.set('poll', null);
  case COMPOSE_POLL_OPTION_ADD:
    return state.updateIn(['poll', 'options'], options => options.push(action.title));
  case COMPOSE_POLL_OPTION_CHANGE:
    return state.setIn(['poll', 'options', action.index], action.title);
  case COMPOSE_POLL_OPTION_REMOVE:
    return state.updateIn(['poll', 'options'], options => options.delete(action.index));
  case COMPOSE_POLL_SETTINGS_CHANGE:
    return state.update('poll', poll => poll.set('expires_in', action.expiresIn).set('multiple', action.isMultiple));
  case COMPOSE_LANGUAGE_CHANGE:
    return state.withMutations(map => {
      map.set('language', action.language);
      map.set('idempotencyKey', uuid());
      map.set('dirty', true);
      rememberManualSetting(map, 'language');
    });
  case COMPOSE_SET_STATUS:
    return state.withMutations(map => {
      abandonStyleDestination(map);
      const media = action.status.get('media_attachments') || ImmutableList();

      map.set('id', action.status.get('id'));
      map.set('text', action.text);
      map.set('in_reply_to', action.status.get('in_reply_to_id'));
      map.set('privacy', action.status.get('visibility') || state.get('privacy'));
      map.set('media_attachments', media.map((item, index) => item.set('order', index).set('unattached', false)));
      map.set('focusDate', new Date());
      map.set('caretPosition', null);
      map.set('idempotencyKey', uuid());
      map.set('sensitive', action.status.get('sensitive'));
      map.set('language', action.status.get('language') || null);
      map.set('dirty', false);

      if ((action.spoiler_text || '').length > 0) {
        map.set('spoiler', true);
        map.set('spoiler_text', action.spoiler_text);
      } else {
        map.set('spoiler', false);
        map.set('spoiler_text', '');
      }

      if (action.status.get('poll')) {
        map.set('poll', ImmutableMap({
          options: action.status.getIn(['poll', 'options']).map(x => typeof x === 'string' ? x : x.get('title')),
          multiple: action.status.getIn(['poll', 'multiple']),
          expires_in: expiresInFromExpiresAt(action.status.getIn(['poll', 'expires_at'])),
        }));
      } else {
        map.set('poll', null);
      }

      // Circle, quote, references, and schedule/expiration belong to a new post.
      // They are immutable on an existing status and must not leak in from the previous draft.
      map.set('quote_from', null);
      map.set('quote_from_url', null);
      map.set('references', ImmutableSet());
      map.set('context_references', ImmutableSet());
      map.set('scheduled', null);
      clearScheduledDraftProvenance(map);
      map.set('expires', null);
      map.set('expires_action', 'mark');
      map.set('circle_id', null);
      map.set('ignore_reference_check', false);
    });
  case COMPOSE_DATETIME_FORM_OPEN:
    if (state.get('id')) return state;
    return state.withMutations(map => {
      map.set('datetime_form', true);
      map.set('default_expires', null);
    });
  case COMPOSE_DATETIME_FORM_CLOSE:
    if (state.get('id')) return state;
    return state.withMutations(map => {
      map.set('datetime_form', null);
      map.set('default_expires', null);
      map.set('scheduled', null);
      map.set('expires', null);
      map.set('expires_action', 'mark');
      map.set('dirty', true);
    });
  case COMPOSE_SCHEDULED_CHANGE:
    if (state.get('id')) return state;
    return state.set('scheduled', action.value).set('dirty', true);
  case COMPOSE_EXPIRES_CHANGE:
    if (state.get('id')) return state;
    return state.set('expires', action.value).set('dirty', true);
  case COMPOSE_EXPIRES_ACTION_CHANGE:
    if (state.get('id')) return state;
    return state.set('expires_action', action.value).set('dirty', true);
  case COMPOSE_MEDIA_ORDER_CHANGE: {
    const list = state.get('media_attachments');
    const index = list.findIndex(item => item.get('id') === action.id);
    const nextIndex = index + action.direction;

    if (index < 0 || nextIndex < 0 || nextIndex >= list.size) {
      return state;
    }

    const reordered = list.delete(index).insert(nextIndex, list.get(index));

    return state
      .set('media_attachments', reordered.map((item, itemIndex) => item.set('order', itemIndex)))
      .set('idempotencyKey', uuid())
      .set('dirty', true);
  }
  case COMPOSE_REFERENCE_ADD:
    if (state.get('id')) return state;
    return state.update('references', set => set.add(action.id));
  case COMPOSE_REFERENCE_REMOVE:
    if (state.get('id')) return state;
    return state.update('references', set => set.delete(action.id));
  case COMPOSE_REFERENCE_RESET:
    if (state.get('id')) return state;
    return state.update('references', set => set.clear());
  case COMPOSE_REFERENCE_CHECK_IGNORE:
    return state.set('ignore_reference_check', true);
  default:
    return state;
  }
};

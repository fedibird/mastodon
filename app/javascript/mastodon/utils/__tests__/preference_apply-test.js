jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { createComposer } from '../../actions/composer';
import { COMPOSE_RESET } from '../../actions/compose';
import { USER_PREFERENCES_DOCUMENT_ACCEPTED } from '../../actions/user_preferences';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import rootReducer from '../../reducers';
import { selectPortableComposerSeed } from '../../selectors/composer';
import {
  selectAcceptedTranslationPreferences,
  selectPreferenceReloadRequired,
} from '../../selectors/user_preferences';
import {
  acceptedPublicValue,
  acceptedTranslationPreferences,
  composerCanFollowPreferenceSelection,
  composerHasDraftContent,
  composerHasUnsavedReloadWork,
  confirmPreferenceReload,
  reloadPreferenceChanged,
  stateHasComposerDraft,
} from '../preference_apply';

const entry = (key, publicValue, options = {}) => ({
  key,
  state: options.state || 'set',
  configured: Object.prototype.hasOwnProperty.call(options, 'configured') ? options.configured : publicValue,
  effective: Object.prototype.hasOwnProperty.call(options, 'effective') ? options.effective : publicValue,
  public_value: publicValue,
  public_valid: options.valid !== false,
  validation_errors: options.valid === false ? [{ field: 'public_value', expected: ['string'], actual: 'nil' }] : [],
});

const documentWith = preferences => ({ version: 1, preferences });

const postingDocument = (overrides = {}) => documentWith({
  'user.default_privacy': entry('user.default_privacy', 'private'),
  'user.default_sensitive': entry('user.default_sensitive', true),
  'user.default_language': entry('user.default_language', 'en'),
  'user.preferred_posting_language': entry('user.preferred_posting_language', 'ja'),
  'user.show_translation_bar': entry('user.show_translation_bar', 'always'),
  'user.translation_preferred_mode': entry('user.translation_preferred_mode', 'bilingual'),
  'user.new_features_policy': entry('user.new_features_policy', 'conservative'),
  ...overrides,
});

const apply = (state, document) => composer(state, {
  type: USER_PREFERENCES_DOCUMENT_ACCEPTED,
  serial: 4,
  document,
});

const fontDocument = (content, info, motion, options = {}) => documentWith({
  'user.content_font_size': entry('user.content_font_size', content, { valid: options.contentValid }),
  'user.info_font_size': entry('user.info_font_size', info, { valid: options.infoValid }),
  'user.reduce_motion': entry('user.reduce_motion', motion, { valid: options.motionValid }),
});

describe('accepted public values', () => {
  it('uses a valid public value and skips invalid, empty, and untyped values', () => {
    const document = documentWith({
      'user.default_privacy': entry('user.default_privacy', 'direct', { configured: 'direct' }),
      'user.default_sensitive': entry('user.default_sensitive', true, { configured: false }),
      'user.preferred_posting_language': entry('user.preferred_posting_language', '', { configured: 'en' }),
      'user.default_language': entry('user.default_language', 'not-a-language', { valid: false, configured: 'ja' }),
      'user.show_translation_bar': entry('user.show_translation_bar', 'nope', { valid: false, configured: 'always' }),
    });

    expect(acceptedPublicValue(document, 'user.default_privacy', value => value === 'direct')).toBe('direct');
    expect(acceptedPublicValue(document, 'user.default_sensitive', value => typeof value === 'boolean')).toBe(true);
    expect(acceptedPublicValue(document, 'user.preferred_posting_language', value => value === null || (typeof value === 'string' && value.trim() !== ''))).toBeUndefined();
    expect(acceptedPublicValue(document, 'user.default_language', () => true)).toBeUndefined();
    expect(acceptedPublicValue(document, 'user.show_translation_bar', () => true)).toBeUndefined();
    expect(acceptedPublicValue(document, 'user.missing', () => true)).toBeUndefined();
    expect(acceptedPublicValue(null, 'user.default_privacy', () => true)).toBeUndefined();
  });

  it('derives translation visibility from policy only when the bar value is not public', () => {
    expect(acceptedTranslationPreferences(postingDocument()).visibility).toBe('always');
    expect(acceptedTranslationPreferences(postingDocument()).preferredMode).toBe('bilingual');

    const fromPolicy = acceptedTranslationPreferences(documentWith({
      'user.show_translation_bar': entry('user.show_translation_bar', null, { valid: false, configured: 'nope' }),
      'user.new_features_policy': entry('user.new_features_policy', 'tester'),
      'user.translation_preferred_mode': entry('user.translation_preferred_mode', 'original', { valid: false }),
    }));

    expect(fromPolicy.visibility).toBe('always');
    expect(fromPolicy.preferredMode).toBe(null);
    expect(acceptedTranslationPreferences(documentWith({
      'user.new_features_policy': entry('user.new_features_policy', 'conservative'),
    })).visibility).toBe('never');
    expect(acceptedTranslationPreferences(documentWith({
      'user.new_features_policy': entry('user.new_features_policy', 'default'),
    })).visibility).toBe('target');
    expect(acceptedTranslationPreferences(documentWith({
      'user.show_translation_bar': entry('user.show_translation_bar', 'nope', { valid: false }),
      'user.new_features_policy': entry('user.new_features_policy', 'sometimes', { valid: false }),
    })).visibility).toBe(null);
    expect(acceptedTranslationPreferences(null)).toEqual({ visibility: null, preferredMode: null });
  });

  it('compares reload keys with the page baseline and ignores an unchanged first read', () => {
    const baselines = { contentFontSize: '15', infoFontSize: 15, reduceMotion: false };

    expect(reloadPreferenceChanged(fontDocument(15, '15', false), baselines)).toBe(false);
    expect(reloadPreferenceChanged(fontDocument(18, 15, false), baselines)).toBe(true);
    expect(reloadPreferenceChanged(fontDocument(15, 16, false), baselines)).toBe(true);
    expect(reloadPreferenceChanged(fontDocument(15, 15, true), baselines)).toBe(true);
    expect(reloadPreferenceChanged(fontDocument('18', 15, false, { contentValid: false }), baselines)).toBe(false);
    expect(reloadPreferenceChanged(fontDocument(18, 15, false), {})).toBe(false);
    expect(reloadPreferenceChanged(null, baselines)).toBe(false);
  });
});

describe('composer preference defaults', () => {
  const idle = composer(undefined, { type: '@@INIT' });

  it('follows privacy and language on an idle composer and leaves sensitive false', () => {
    expect(composerCanFollowPreferenceSelection(idle)).toBe(true);

    const next = apply(idle, postingDocument());

    expect(next.get('default_privacy')).toBe('private');
    expect(next.get('privacy')).toBe('private');
    expect(next.get('default_language')).toBe('ja');
    expect(next.get('language')).toBe('ja');
    expect(next.get('default_sensitive')).toBe(true);
    expect(next.get('sensitive')).toBe(false);
    expect(next.get('default_searchability')).toBe(idle.get('default_searchability'));
    expect(next.get('text')).toBe('');
    expect(next.get('senderIdentity')).toBe(idle.get('senderIdentity'));
    expect(next.get('userPostingStyle')).toBe(idle.get('userPostingStyle'));
  });

  it('does not treat raw default_language, empty language, or non-selectable privacy as composer defaults', () => {
    const document = documentWith({
      'user.default_privacy': entry('user.default_privacy', 'direct', { configured: 'private' }),
      'user.default_language': entry('user.default_language', 'en'),
      'user.preferred_posting_language': entry('user.preferred_posting_language', '  ', { configured: null }),
      'user.default_sensitive': entry('user.default_sensitive', 'true', { valid: false, configured: true }),
    });
    const next = apply(idle, document);

    expect(next).toBe(idle);
  });

  it('applies the valid keys when another key is invalid', () => {
    const document = postingDocument({
      'user.preferred_posting_language': entry('user.preferred_posting_language', null, { valid: false, configured: 'fr' }),
      'user.default_language': entry('user.default_language', 'fr'),
    });
    const next = apply(idle, document);

    expect(next.get('default_privacy')).toBe('private');
    expect(next.get('privacy')).toBe('private');
    expect(next.get('default_language')).toBe(null);
    expect(next.get('language')).toBe(null);
    expect(next.get('default_sensitive')).toBe(true);
  });

  it('accepts a null derived posting language', () => {
    const next = apply(idle.set('language', null), documentWith({
      'user.preferred_posting_language': entry('user.preferred_posting_language', null, { configured: null }),
    }));

    expect(next.get('default_language')).toBe(null);
    expect(next.get('language')).toBe(null);
  });

  it.each([
    ['text', state => state.set('text', '下書きです')],
    ['spoiler', state => state.set('spoiler', true).set('spoiler_text', 'cw')],
    ['media', state => state.set('media_attachments', ImmutableList([ImmutableMap({ id: '1' })])).set('sensitive', true)],
    ['upload', state => state.set('pending_media_attachments', 1).set('is_uploading', true)],
    ['poll', state => state.set('poll', ImmutableMap({ options: ImmutableList(['a', 'b']) }))],
    ['reply', state => state.set('in_reply_to', '1').set('privacy', 'unlisted')],
    ['quote', state => state.set('quote_from', '2')],
    ['edit', state => state.set('id', '9').set('text', 'edit')],
    ['scheduled', state => state.set('scheduled', '2026-10-15T00:00:00Z').set('scheduled_status_id', '4')],
    ['references', state => state.set('references', ImmutableList(['3']))],
    ['redraft', state => state.set('redraftMediaUnconfirmed', true)],
    ['manual privacy', state => state.set('privacy', 'unlisted').set('dirty', true)],
    ['group context', state => state.setIn(['context', 'key'], 'group:1').setIn(['context', 'managed', 'hashtags'], ImmutableList([ImmutableMap({ name: 'news' })]))],
    ['posting style', state => state.setIn(['userPostingStyle', 'selectedId'], 'style-1')],
    ['delegated identity', state => state.setIn(['senderIdentity', 'id'], 'delegated:9').setIn(['senderIdentity', 'selectionOrigin'], 'explicit')],
    ['surface', state => state.set('surface', ImmutableMap({ kind: 'group', key: '1' }))],
  ])('keeps the current selection for a %s composer', (_label, occupy) => {
    const occupied = occupy(idle.set('privacy', 'public').set('language', null));
    const next = apply(occupied, postingDocument());

    expect(next.get('text')).toBe(occupied.get('text'));
    expect(next.get('spoiler_text')).toBe(occupied.get('spoiler_text'));
    expect(next.get('media_attachments')).toBe(occupied.get('media_attachments'));
    expect(next.get('poll')).toBe(occupied.get('poll'));
    expect(next.get('in_reply_to')).toBe(occupied.get('in_reply_to'));
    expect(next.get('quote_from')).toBe(occupied.get('quote_from'));
    expect(next.get('id')).toBe(occupied.get('id'));
    expect(next.get('scheduled')).toBe(occupied.get('scheduled'));
    expect(next.get('references')).toBe(occupied.get('references'));
    expect(next.get('privacy')).toBe(occupied.get('privacy'));
    expect(next.get('language')).toBe(occupied.get('language'));
    expect(next.get('sensitive')).toBe(occupied.get('sensitive'));
    expect(next.get('senderIdentity')).toBe(occupied.get('senderIdentity'));
    expect(next.get('userPostingStyle')).toBe(occupied.get('userPostingStyle'));
    expect(next.get('context')).toBe(occupied.get('context'));
    expect(next.get('default_privacy')).toBe('private');
    expect(next.get('default_language')).toBe('ja');
    expect(next.get('default_sensitive')).toBe(true);
    expect(next.get('default_searchability')).toBe(occupied.get('default_searchability'));
  });

  it('uses the updated defaults after reset without keeping the draft', () => {
    const drafted = apply(idle.set('text', '下書きです').set('privacy', 'unlisted').set('dirty', true), postingDocument());
    const reset = composer(drafted, { type: COMPOSE_RESET });

    expect(drafted.get('text')).toBe('下書きです');
    expect(drafted.get('privacy')).toBe('unlisted');
    expect(reset.get('text')).toBe('');
    expect(reset.get('privacy')).toBe('private');
    expect(reset.get('language')).toBe('ja');
    expect(reset.get('sensitive')).toBe(false);
    expect(reset.get('default_sensitive')).toBe(true);
  });

  it('updates every portable composer and seeds a later one from the primary defaults', () => {
    const drafted = composers(undefined, createComposer('composer-draft'));
    const withDraft = drafted.setIn(['byId', 'composer-draft', 'text'], 'portable draft')
      .setIn(['byId', 'composer-draft', 'privacy'], 'unlisted')
      .setIn(['byId', 'composer-draft', 'dirty'], true);
    const idlePortable = composers(withDraft, createComposer('composer-idle'));
    const updated = composers(idlePortable, {
      type: USER_PREFERENCES_DOCUMENT_ACCEPTED,
      document: postingDocument(),
    });
    const primary = apply(idle, postingDocument());
    const seed = selectPortableComposerSeed(ImmutableMap({ compose: primary }));
    const created = composers(updated, createComposer('composer-new', seed)).getIn(['byId', 'composer-new']);

    expect(updated.getIn(['byId', 'composer-draft', 'text'])).toBe('portable draft');
    expect(updated.getIn(['byId', 'composer-draft', 'privacy'])).toBe('unlisted');
    expect(updated.getIn(['byId', 'composer-draft', 'default_privacy'])).toBe('private');
    expect(updated.getIn(['byId', 'composer-draft', 'default_language'])).toBe('ja');
    expect(updated.getIn(['byId', 'composer-idle', 'privacy'])).toBe('private');
    expect(updated.getIn(['byId', 'composer-idle', 'language'])).toBe('ja');
    expect(updated.getIn(['byId', 'composer-idle', 'sensitive'])).toBe(false);
    expect(created.get('default_privacy')).toBe('private');
    expect(created.get('privacy')).toBe('private');
    expect(created.get('default_language')).toBe('ja');
    expect(created.get('language')).toBe('ja');
    expect(created.get('default_sensitive')).toBe(true);
    expect(created.get('sensitive')).toBe(false);
    expect(created.get('default_searchability')).toBe(primary.get('default_searchability'));
  });

  it('leaves meta, settings, and stored statuses untouched', () => {
    const before = rootReducer(undefined, { type: '@@INIT' });
    const status = before.get('statuses');
    const after = rootReducer(before, {
      type: USER_PREFERENCES_DOCUMENT_ACCEPTED,
      serial: 1,
      document: postingDocument(),
    });

    expect(after.get('meta')).toEqual(before.get('meta'));
    expect(after.get('settings')).toEqual(before.get('settings'));
    expect(after.get('statuses')).toBe(status);
    expect(after.get('userPostingStyles')).toEqual(before.get('userPostingStyles'));
    expect(after.getIn(['user_preferences', 'document'])).toBe(null);
    expect(after.getIn(['compose', 'default_privacy'])).toBe('private');
    expect(after.getIn(['compose', 'default_language'])).toBe('ja');
  });

  it('reads translation and reload state from the accepted document only', () => {
    const document = postingDocument({
      'user.content_font_size': entry('user.content_font_size', 18),
      'user.info_font_size': entry('user.info_font_size', 15),
      'user.reduce_motion': entry('user.reduce_motion', false),
    });
    const state = ImmutableMap({
      meta: ImmutableMap({
        content_font_size: 15,
        info_font_size: 15,
        reduce_motion: false,
      }),
      user_preferences: ImmutableMap({ document }),
    });

    expect(selectAcceptedTranslationPreferences(state)).toEqual({
      visibility: 'always',
      preferredMode: 'bilingual',
    });
    expect(selectPreferenceReloadRequired(state)).toBe(true);
    expect(selectPreferenceReloadRequired(state.setIn(['user_preferences', 'document'], fontDocument(15, 15, false)))).toBe(false);
    expect(selectAcceptedTranslationPreferences(ImmutableMap())).toEqual({ visibility: null, preferredMode: null });
  });
});

describe('preference reload confirmation', () => {
  it('reloads immediately when nothing is drafted and asks before discarding a draft', () => {
    const reload = jest.fn();
    const confirm = jest.fn(() => false);

    expect(confirmPreferenceReload({ hasDraft: false, confirm, reload, message: 'lose drafts?' })).toBe(true);
    expect(confirm).not.toHaveBeenCalled();
    expect(reload).toHaveBeenCalledTimes(1);

    expect(confirmPreferenceReload({ hasDraft: true, confirm, reload, message: 'lose drafts?' })).toBe(false);
    expect(confirm).toHaveBeenCalledWith('lose drafts?');
    expect(reload).toHaveBeenCalledTimes(1);

    confirm.mockReturnValue(true);
    expect(confirmPreferenceReload({ hasDraft: true, confirm, reload, message: 'lose drafts?' })).toBe(true);
    expect(reload).toHaveBeenCalledTimes(2);
  });

  it('treats a portable draft as unsaved work', () => {
    const state = ImmutableMap({
      compose: ImmutableMap({ text: '' }),
      composers: ImmutableMap({
        byId: ImmutableMap({
          'composer-a': ImmutableMap({ text: 'portable draft' }),
        }),
      }),
    });

    expect(stateHasComposerDraft(state)).toBe(true);
    expect(stateHasComposerDraft(state.setIn(['composers', 'byId', 'composer-a', 'text'], '  '))).toBe(true);
  });

  const storeWith = (compose, portables = {}) => ImmutableMap({
    compose: ImmutableMap({ text: '', dirty: false }).merge(compose),
    composers: ImmutableMap({
      byId: ImmutableMap(Object.keys(portables).reduce((byId, id) => {
        byId[id] = ImmutableMap({ text: '', dirty: false }).merge(portables[id]);
        return byId;
      }, {})),
    }),
  });

  it('asks to confirm a manual privacy, language, or sensitive change with an empty body', () => {
    const privacy = storeWith({ privacy: 'unlisted', dirty: true });
    const language = storeWith({ language: 'ja', dirty: true });
    const sensitive = storeWith({ sensitive: true, dirty: true });

    [privacy, language, sensitive].forEach(state => {
      expect(stateHasComposerDraft(state)).toBe(true);
      expect(composerHasUnsavedReloadWork(state.get('compose'))).toBe(true);
      expect(composerHasDraftContent(state.get('compose'))).toBe(false);
      expect(composerCanFollowPreferenceSelection(state.get('compose'))).toBe(false);
    });
  });

  it('treats whitespace as typed text and a non-empty body as unsaved work', () => {
    const spaces = storeWith({ text: '   ' });
    const typed = storeWith({ text: 'hello', dirty: true });

    expect(composerHasDraftContent(spaces.get('compose'))).toBe(false);
    expect(composerHasUnsavedReloadWork(spaces.get('compose'))).toBe(true);
    expect(composerCanFollowPreferenceSelection(spaces.get('compose'))).toBe(true);
    expect(stateHasComposerDraft(spaces)).toBe(true);
    expect(stateHasComposerDraft(typed)).toBe(true);
    expect(stateHasComposerDraft(storeWith({ text: '' }))).toBe(false);
  });

  it('confirms when only a portable composer has unsaved work', () => {
    const state = storeWith({}, {
      'composer-a': { text: '', dirty: false },
      'composer-b': { text: '', privacy: 'private', dirty: true },
    });

    expect(stateHasComposerDraft(state)).toBe(true);
    expect(composerHasUnsavedReloadWork(state.get('compose'))).toBe(false);
  });

  it('confirms for an open datetime form, media edit, upload, reply, quote, edit, schedule, or redraft', () => {
    const cases = [
      { datetime_form: true },
      { media_modal: ImmutableMap({ id: 'media-1', dirty: true, description: 'alt' }) },
      { is_uploading: true, pending_media_attachments: 1 },
      { in_reply_to: '1' },
      { quote_from: '2' },
      { id: '9' },
      { scheduled: '2026-10-15T00:00:00Z', scheduled_status_id: '4' },
      { redraftMediaUnconfirmed: true },
      { spoiler_text: ' ' },
    ];

    cases.forEach(fields => {
      expect(stateHasComposerDraft(storeWith(fields))).toBe(true);
    });
  });

  it('does not confirm for an idle composer or an automatic posting context', () => {
    const idle = composer(undefined, { type: '@@INIT' });
    const contextual = idle
      .set('surface', ImmutableMap({ kind: 'hashtag', key: 'fedibird' }))
      .set('posting_context_account_id', '1')
      .setIn(['context', 'key'], 'builtin:hashtag:fedibird')
      .setIn(['context', 'source'], 'timeline')
      .setIn(['context', 'managed', 'hashtags'], ImmutableList([ImmutableMap({ name: 'fedibird' })]));

    expect(composerCanFollowPreferenceSelection(idle)).toBe(true);
    expect(composerHasUnsavedReloadWork(idle)).toBe(false);
    expect(stateHasComposerDraft(storeWith(idle))).toBe(false);
    expect(composerCanFollowPreferenceSelection(contextual)).toBe(false);
    expect(composerHasUnsavedReloadWork(contextual)).toBe(false);
    expect(stateHasComposerDraft(storeWith(contextual))).toBe(false);
    expect(stateHasComposerDraft(storeWith(contextual, {
      'composer-context': contextual,
    }))).toBe(false);
  });

  it('confirms an explicit posting style or sender and ignores automatic ones', () => {
    const manualStyle = {
      text: '',
      dirty: false,
      userPostingStyle: ImmutableMap({ selectionOrigin: 'manual', selectedId: 'style-1' }),
    };
    const clearedStyle = {
      text: '',
      dirty: false,
      userPostingStyle: ImmutableMap({ selectionOrigin: 'none', selectedId: null }),
    };
    const explicitSender = {
      text: '',
      dirty: false,
      senderIdentity: ImmutableMap({ id: 'delegated:9', selectionOrigin: 'explicit', status: 'ready' }),
    };

    [manualStyle, clearedStyle, explicitSender].forEach(fields => {
      expect(stateHasComposerDraft(storeWith(fields))).toBe(true);
      expect(composerHasDraftContent(storeWith(fields).get('compose'))).toBe(false);
    });

    expect(stateHasComposerDraft(storeWith({}, {
      'composer-style': manualStyle,
    }))).toBe(true);
    expect(stateHasComposerDraft(storeWith({}, {
      'composer-sender': explicitSender,
    }))).toBe(true);

    ['automatic', 'saved_default'].forEach(origin => {
      const automatic = storeWith({
        text: '',
        dirty: false,
        userPostingStyle: ImmutableMap({ selectionOrigin: origin, selectedId: 'style-1' }),
        senderIdentity: ImmutableMap({ id: 'local:1', selectionOrigin: 'default', status: 'ready' }),
      });

      expect(composerHasUnsavedReloadWork(automatic.get('compose'))).toBe(false);
      expect(composerCanFollowPreferenceSelection(automatic.get('compose'))).toBe(false);
      expect(stateHasComposerDraft(automatic)).toBe(false);
    });

    const releasedBySurface = storeWith({
      text: '',
      dirty: false,
      surface: ImmutableMap({ kind: 'group', key: '123' }),
      userPostingStyle: ImmutableMap({ selectionOrigin: null, selectedId: null }),
    });

    expect(stateHasComposerDraft(releasedBySurface)).toBe(false);
    expect(composerCanFollowPreferenceSelection(storeWith(manualStyle).get('compose'))).toBe(false);
  });
});

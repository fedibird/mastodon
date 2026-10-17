import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));

import composer, { hydrateComposer, initialState } from '../composer';
import composers from '../composers';
import { createComposer, targetComposerAction } from '../../actions/composer';
import { searchabilityIsChanged } from '../../utils/searchability';

const seed = fromJS({ default_privacy: 'private', default_searchability: 'public' });
const hydrated = () => hydrateComposer(initialState, seed);
const changePrivacy = (state, value) => composer(state, { type: 'COMPOSE_VISIBILITY_CHANGE', value });
const changeSearch = (state, value) => composer(state, { type: 'COMPOSE_SEARCHABILITY_CHANGE', value });
const document = privacy => ({ preferences: {
  'user.default_privacy': { public_valid: true, public_value: privacy },
} });
const accepted = privacy => ({ type: 'USER_PREFERENCES_DOCUMENT_ACCEPTED', document: document(privacy) });
const status = fromJS({ id: 'post', visibility: 'public', mentions: [], spoiler_text: '', media_attachments: [], content: '', account: { acct: 'alice' } });

describe('effective composer searchability across entry paths', () => {
  it.each(['public', 'private', 'direct'])('caps the account preference %s on hydrate, reset and submit success', desired => {
    let state = hydrateComposer(initialState, seed.set('default_searchability', desired));
    const expected = desired === 'direct' ? 'direct' : 'private';

    ['@@INIT', 'COMPOSE_RESET', 'COMPOSE_SUBMIT_SUCCESS', 'SCHEDULED_STATUS_SUBMIT_SUCCESS', 'COMPOSE_EDIT_CANCEL'].forEach(type => {
      state = composer(state, { type });
      expect(state.get('privacy')).toBe('private');
      expect(state.get('searchability')).toBe(expected);
      expect(state.get('default_searchability')).toBe(desired);
      expect(searchabilityIsChanged({ searchability: state.get('searchability'), privacy: 'private', defaultSearchability: desired })).toBe(false);
    });
  });

  it.each(['COMPOSE_REPLY', 'COMPOSE_QUOTE'])('uses the final default-capped privacy for %s', type => {
    const state = composer(hydrated(), { type, status, context_references: [] });

    expect(state.get('privacy')).toBe('private');
    expect(state.get('searchability')).toBe('private');
  });

  it('restores the desired default across privacy changes but preserves explicit narrower choices', () => {
    let state = changePrivacy(hydrated(), 'public');

    expect(state.get('searchability')).toBe('public');
    state = changePrivacy(state, 'private');
    expect(state.get('searchability')).toBe('private');
    state = changePrivacy(state, 'public');
    expect(state.get('searchability')).toBe('public');
    state = changeSearch(state, 'private');
    state = changePrivacy(state, 'direct');
    expect(state.get('searchability')).toBe('direct');
    state = changePrivacy(state, 'public');
    expect(state.get('searchability')).toBe('private');
    state = changeSearch(state, 'direct');
    state = changePrivacy(changePrivacy(state, 'private'), 'public');
    expect(state.get('searchability')).toBe('direct');
    state = composer(state, { type: 'COMPOSE_SEARCHABILITY_RESET' });
    expect(state.get('searchability')).toBe('public');
  });

  it('never changes the post privacy, text or circle when a wider search value is requested', () => {
    const before = hydrated().set('text', 'draft').set('circle_id', 'circle');
    const after = changeSearch(before, 'public');

    expect(after.get('privacy')).toBe('private');
    expect(after.get('searchability')).toBe('private');
    expect(after.get('text')).toBe('draft');
    expect(after.get('circle_id')).toBe('circle');
  });

  it('caps redraft fallback values and retains saved narrower values when privacy widens', () => {
    let state = composer(hydrated(), { type: 'REDRAFT', status: status.set('visibility', 'private'), raw_text: 'redraft', replyStatus: null, context_references: [] });

    expect(state.get('searchability')).toBe('private');
    state = composer(state, { type: 'REDRAFT', status: status.set('visibility', 'private').set('searchability', 'direct'), raw_text: 'redraft', replyStatus: null, context_references: [] });
    state = changePrivacy(state, 'public');
    expect(state.get('searchability')).toBe('direct');
  });

  it('initializes existing edit searchability from the status and keeps both fields readonly', () => {
    const edit = composer(hydrated(), { type: 'COMPOSE_SET_STATUS', status: status.set('visibility', 'private').set('searchability', 'public'), text: 'edit' });

    expect(edit.get('searchability')).toBe('private');
    expect(changePrivacy(edit, 'public')).toBe(edit);
    expect(changeSearch(edit, 'public')).toBe(edit);
    expect(composer(edit, { type: 'COMPOSE_SEARCHABILITY_RESET' })).toBe(edit);
  });

  it('follows accepted defaults for idle primary and portable composers while protecting drafts and explicit selections', () => {
    let registry = composers(undefined, createComposer('idle', seed));

    registry = composers(registry, createComposer('draft', seed));
    registry = composers(registry, createComposer('manual', seed));
    registry = composers(registry, targetComposerAction({ type: 'COMPOSE_CHANGE', text: 'draft' }, 'draft'));
    registry = composers(registry, targetComposerAction({ type: 'COMPOSE_SEARCHABILITY_CHANGE', value: 'direct' }, 'manual'));
    registry = composers(registry, accepted('public'));
    expect(registry.getIn(['byId', 'idle', 'searchability'])).toBe('public');
    expect(registry.getIn(['byId', 'draft', 'privacy'])).toBe('private');
    expect(registry.getIn(['byId', 'draft', 'text'])).toBe('draft');
    expect(registry.getIn(['byId', 'manual', 'searchability'])).toBe('direct');
    registry = composers(registry, accepted('private'));
    expect(registry.getIn(['byId', 'idle', 'searchability'])).toBe('private');
    expect(composer(composer(hydrated(), accepted('public')), accepted('private')).get('searchability')).toBe('private');
  });

  it('safely normalizes an invalid legacy draft without changing draft content', () => {
    const state = hydrated().set('text', 'keep me').set('searchability', 'public');
    const after = composer(state, accepted('public'));

    expect(after.get('privacy')).toBe('private');
    expect(after.get('searchability')).toBe('private');
    expect(after.get('text')).toBe('keep me');
  });
});

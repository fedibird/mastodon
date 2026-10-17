import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { changeCompose, changeComposeSearchability, changeComposeVisibility, resetComposeSearchability, COMPOSE_LANGUAGE_CHANGE, COMPOSE_QUOTE, COMPOSE_REPLY } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import composer from '../composer';
import composers from '../composers';
import { searchabilityIsChanged } from '../../utils/searchability';

const registry = (id = 'composer-a') => {
  let state = composers(undefined, { type: '@@INIT' });

  state = composers(state, createComposer(id));

  return state;
};

const changed = state => searchabilityIsChanged({
  searchability: state.get('searchability'),
  privacy: state.get('privacy'),
  defaultSearchability: state.get('default_searchability'),
  privacyBeforeSearchability: state.get('privacy_before_searchability'),
});

const directStatus = () => ImmutableMap({
  id: 'status-1',
  visibility: 'direct',
  spoiler_text: '',
  url: 'https://example.test/1',
  mentions: ImmutableList(),
});

describe('searchability reset', () => {
  it('caps a wider search selection without changing privacy or showing a false override', () => {
    let state = composer(undefined, { type: '@@INIT' });

    state = composer(state, changeComposeVisibility('direct'));
    state = composer(state, changeComposeSearchability('private'));

    expect(state.get('default_searchability')).toBe('private');
    expect(state.get('privacy')).toBe('direct');
    expect(state.get('searchability')).toBe('direct');
    expect(state.get('privacy_before_searchability')).toBeNull();
    expect(state.get('searchability_manual')).toBe(true);
    expect(changed(state)).toBe(false);

    state = composer(state, resetComposeSearchability());

    expect(state.get('privacy')).toBe('direct');
    expect(state.get('searchability')).toBe('direct');
    expect(state.get('privacy_before_searchability')).toBeNull();
    expect(state.get('searchability_manual')).toBe(false);
    expect(changed(state)).toBe(false);
  });

  it('does not mark an automatic reply or quote cap as a manual change', () => {
    let reply = composer(undefined, { type: '@@INIT' });
    let quote = composer(undefined, { type: '@@INIT' });
    const status = directStatus();

    reply = composer(reply, { type: COMPOSE_REPLY, status, context_references: [] });
    quote = composer(quote, { type: COMPOSE_QUOTE, status });

    [reply, quote].forEach(state => {
      expect(state.get('privacy')).toBe('direct');
      expect(state.get('searchability')).toBe('direct');
      expect(state.get('default_searchability')).toBe('private');
      expect(state.get('privacy_before_searchability')).toBeNull();
      expect(state.get('searchability_manual')).toBe(false);
      expect(changed(state)).toBe(false);
    });
  });

  it('returns a normal post to the effective default without widening privacy', () => {
    let state = registry();

    state = composers(state, targetComposerAction(changeCompose('hello'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeVisibility('private'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeSearchability('public'), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');

    state = composers(state, targetComposerAction(resetComposeSearchability(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('hello');
    expect(state.getIn(['byId', 'composer-b'])).toBeUndefined();
  });

  it('does not treat a private reply as a manual searchability change', () => {
    let state = registry();
    const status = ImmutableMap({
      id: 'status-1',
      visibility: 'private',
      spoiler_text: '',
      url: 'https://example.test/1',
      mentions: ImmutableList(),
    });

    state = composers(state, targetComposerAction({
      type: COMPOSE_REPLY,
      status,
      context_references: [],
    }, 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability_manual'])).toBe(false);

    state = composers(state, targetComposerAction(resetComposeSearchability(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
  });

  it('keeps a later manual privacy choice when searchability is reset', () => {
    let state = registry();

    state = composers(state, targetComposerAction(changeComposeSearchability('public'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeVisibility('unlisted'), 'composer-a'));
    state = composers(state, targetComposerAction(resetComposeSearchability(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('unlisted');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
  });

  it('keeps another composer unchanged', () => {
    let state = composers(undefined, { type: '@@INIT' });

    state = composers(state, createComposer('composer-a'));
    state = composers(state, createComposer('composer-b'));
    state = composers(state, targetComposerAction(changeCompose('a'), 'composer-a'));
    state = composers(state, targetComposerAction(changeCompose('b'), 'composer-b'));
    state = composers(state, targetComposerAction(changeComposeSearchability('direct'), 'composer-a'));
    state = composers(state, targetComposerAction(resetComposeSearchability(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
    expect(state.getIn(['byId', 'composer-b', 'text'])).toBe('b');
    expect(state.getIn(['byId', 'composer-b', 'searchability'])).toBeNull();
  });

  it('changes the posting language of only one composer', () => {
    let state = composers(undefined, { type: '@@INIT' });

    state = composers(state, createComposer('composer-a'));
    state = composers(state, createComposer('composer-b'));
    state = composers(state, targetComposerAction({ type: COMPOSE_LANGUAGE_CHANGE, language: 'en' }, 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'language'])).toBe('en');
    expect(state.getIn(['byId', 'composer-b', 'language'])).toBeNull();
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('');
  });
});

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { changeCompose, changeComposeSearchability, changeComposeVisibility, resetComposeSearchability, COMPOSE_LANGUAGE_CHANGE } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import { COMPOSE_REPLY } from '../../actions/compose';
import composers from '../composers';

const composer = (id = 'composer-a') => {
  let state = composers(undefined, { type: '@@INIT' });

  state = composers(state, createComposer(id));

  return state;
};

describe('searchability reset', () => {
  it('returns a normal post to the effective default without widening privacy', () => {
    let state = composer();

    state = composers(state, targetComposerAction(changeCompose('hello'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeVisibility('private'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeSearchability('public'), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('public');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('public');

    state = composers(state, targetComposerAction(resetComposeSearchability(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('hello');
    expect(state.getIn(['byId', 'composer-b'])).toBeUndefined();
  });

  it('does not treat a private reply as a manual searchability change', () => {
    let state = composer();
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
    let state = composer();

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

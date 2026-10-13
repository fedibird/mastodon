jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { addDateTime, addPoll, changeCompose, changeComposeSearchability, changeComposeSpoilerness, removeDateTime, removePoll } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import composers from '../composers';

const openPair = () => {
  let state = composers(undefined, { type: '@@INIT' });

  state = composers(state, createComposer('composer-a'));
  state = composers(state, createComposer('composer-b'));
  state = composers(state, targetComposerAction(changeCompose('hello a'), 'composer-a'));
  state = composers(state, targetComposerAction(changeCompose('hello b'), 'composer-b'));

  return state;
};

describe('composer close controls', () => {
  it('removes a poll from only the composer that was closed', () => {
    let state = openPair();

    state = composers(state, targetComposerAction(addPoll(), 'composer-a'));
    state = composers(state, targetComposerAction(addPoll(), 'composer-b'));
    state = composers(state, targetComposerAction(removePoll(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'poll'])).toBeNull();
    expect(state.getIn(['byId', 'composer-b', 'poll'])).not.toBeNull();
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('hello a');
    expect(state.getIn(['byId', 'composer-b', 'text'])).toBe('hello b');
  });

  it('turns off a content warning without clearing the other composer', () => {
    let state = openPair();

    state = composers(state, targetComposerAction(changeComposeSpoilerness(), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeSpoilerness(), 'composer-b'));
    state = composers(state, targetComposerAction(changeComposeSpoilerness(), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'spoiler'])).toBe(false);
    expect(state.getIn(['byId', 'composer-b', 'spoiler'])).toBe(true);
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('hello a');
  });

  it('closes datetime settings on one composer and restores searchability only there', () => {
    let state = openPair();

    state = composers(state, targetComposerAction(addDateTime(), 'composer-a'));
    state = composers(state, targetComposerAction(addDateTime(), 'composer-b'));
    state = composers(state, targetComposerAction(changeComposeSearchability('private'), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeSearchability('private'), 'composer-b'));
    state = composers(state, targetComposerAction(removeDateTime(), 'composer-a'));
    state = composers(state, targetComposerAction(changeComposeSearchability(state.getIn(['byId', 'composer-a', 'default_searchability'])), 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'datetime_form'])).toBeNull();
    expect(state.getIn(['byId', 'composer-a', 'scheduled'])).toBeNull();
    expect(state.getIn(['byId', 'composer-a', 'expires'])).toBeNull();
    expect(state.getIn(['byId', 'composer-b', 'datetime_form'])).toBe(true);
    expect(state.getIn(['byId', 'composer-a', 'searchability'])).toBe(state.getIn(['byId', 'composer-a', 'default_searchability']));
    expect(state.getIn(['byId', 'composer-b', 'searchability'])).toBe('private');
    expect(state.getIn(['byId', 'composer-a', 'text'])).toBe('hello a');
  });
});

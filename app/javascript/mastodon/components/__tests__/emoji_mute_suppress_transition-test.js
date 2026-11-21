/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { connect, Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  reduceMotion: true,
  hideReactionCounter: true,
  hideListOfEmojiReactionsToPosts: true,
  disableReactions: false,
  emojiPickerDisabled: false,
}));

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import DisplayName from 'mastodon/components/display_name';
import EmojiReactionsBar from 'mastodon/components/emoji_reactions_bar';
import { createUnverifiedEmojiGuard, emojiMuteLiveDomProbe, resetEmojiMuteLiveDomProbe } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

const OK = '👌';
const KEEP = '✨';

const emojiImg = native => `<img class="emojione" alt="${native}" title="${native}" src="/emoji/${native}.svg" srcset="/emoji/${native}.svg 2x">`;

const nameHtml = `Hi ${emojiImg(OK)} ${emojiImg(KEEP)} <img src="/media/x.jpg" alt="photo ${OK}" srcset="/media/x.jpg 2x">`;

const account = fromJS({ id: 'a1', acct: 'alice', display_name_html: nameHtml });

const status = fromJS({
  id: 's1',
  account: 'a1',
  emoji_reactions: [{ name: OK, count: 1, account_ids: ['2'], url: 'https://cdn.example/reaction.svg', static_url: 'https://cdn.example/reaction.png' }],
});

const reducer = (state, action) => {
  if (!state) {
    return fromJS({
      compose: { text: '' },
      relationships: {},
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'apply',
      },
    });
  }

  if (action.type === 'COMPOSE_TYPE') {
    return state.setIn(['compose', 'text'], action.text);
  }

  if (action.type === 'UNRELATED') {
    return state;
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

const Composer = connect(state => ({ text: state.getIn(['compose', 'text']) }))(
  class ComposerField extends React.PureComponent {

    onChange = event => {
      this.props.dispatch({ type: 'COMPOSE_TYPE', text: event.target.value });
    };

    render() {
      return <input aria-label='compose' value={this.props.text} onChange={this.onChange} />;
    }

  },
);

describe('mounted suppress transition', () => {
  it('conceals painted emoji once, lets React restore the nodes, and does not rescan typing', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const during = [];

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const emoji = document.querySelector('img.emojione');
      during.push(emoji ? emoji.outerHTML : null);
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <DisplayName account={account} />
          <EmojiReactionsBar status={status} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
          <Composer />
        </div>
      </Provider>,
    );

    expect(view.container.querySelectorAll('img.emojione').length).toBeGreaterThan(0);
    expect(emojiMuteLiveDomProbe.scans).toBe(0);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    const concealed = during[during.length - 1];
    expect(concealed).toContain('emojione');
    expect(concealed).not.toContain(`/emoji/${OK}.svg`);
    expect(concealed).toContain('hidden');
    expect(view.container.querySelector('img[src="/media/x.jpg"]').getAttribute('alt')).toBe('photo ◻');
    expect(view.container.querySelector('img[src="/media/x.jpg"]').getAttribute('srcset')).toBe('/media/x.jpg 2x');
    expect(view.container.innerHTML).not.toContain(`/emoji/${OK}.svg`);
    expect(view.container.innerHTML).not.toContain(`/emoji/${KEEP}.svg`);
    expect(view.container.innerHTML).not.toContain('cdn.example/reaction.svg');
    expect(view.container.querySelector('.emoji-reactions-bar')).toBeNull();
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({ type: 'UNRELATED' });
    });
    fireEvent.change(view.getByLabelText('compose'), { target: { value: `draft ${OK}` } });

    expect(view.getByLabelText('compose').value).toBe(`draft ${OK}`);
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [{
          id: 'm1',
          revision: '3',
          emoji: { kind: 'unicode', native: OK },
          replacement: '[ok]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(view.container.innerHTML).toContain(`/emoji/${KEEP}.svg`);
    expect(view.container.innerHTML).not.toContain(`/emoji/${OK}.svg`);
    expect(view.container.innerHTML).toContain('[ok]');
    expect(view.container.querySelector('img[src="/media/x.jpg"]').getAttribute('alt')).toBe(`photo ${OK}`);
    expect(view.container.querySelector('.emoji-reactions-bar')).not.toBeNull();
    expect(() => view.unmount()).not.toThrow();
  });
});

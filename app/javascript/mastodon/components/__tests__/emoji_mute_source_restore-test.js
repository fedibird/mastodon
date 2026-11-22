/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { connect, Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
}));

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import CustomEmojiText from 'mastodon/components/custom_emoji_text';
import { createUnverifiedEmojiGuard, emojiMuteLiveDomProbe, resetEmojiMuteLiveDomProbe } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { bindEmojiMuteElementSource, bindEmojiMuteHtmlSources } from 'mastodon/features/emoji/emoji_mute_sources';
import { emojiMuteTextIndexFromState, presentEmojiMutePlain } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

const OK = '👌';
const SPARKLE = '✨';
const SMILE = '🙂';

const reducer = (state, action) => {
  if (!state) {
    return fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'apply',
      },
      title: `Hi ${OK}`,
    });
  }

  if (action.type === 'SET_TITLE') {
    return state.set('title', action.title);
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

const chain = [
  {
    id: 'm1',
    revision: '3',
    emoji: { kind: 'unicode', native: OK },
    replacement: SPARKLE,
    effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
  },
  {
    id: 'm2',
    revision: '3',
    emoji: { kind: 'unicode', native: SPARKLE },
    replacement: '[sparkles]',
    effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
  },
];

const Title = connect(state => ({
  title: state.get('title'),
}))(class TitleText extends React.PureComponent {

  componentDidMount () {
    this.bind();
  }

  componentDidUpdate () {
    this.bind();
  }

  bind () {
    bindEmojiMuteElementSource(this.node, this.props.title);
  }

  setNode = node => {
    this.node = node;
  }

  render () {
    const index = this.props.emojiMuteTextIndex;

    return (
      <div ref={this.setNode} className='card-title'>
        {presentEmojiMutePlain(this.props.title, index)}
      </div>
    );
  }

});

const ConnectedTitle = connect(state => ({
  emojiMuteTextIndex: emojiMuteTextIndexFromState(state),
}))(Title);

describe('emoji mute source restore', () => {
  it('projects a custom emoji label once across a same-batch success', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);

    store.subscribe(() => guard(store.getState()));
    let atRelease = null;

    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) === '4' && store.getState().getIn(['emojiMutes', 'display']) === 'apply') {
        atRelease = document.querySelector('.emoji-mutes-privacy-portal').textContent;
      }
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CustomEmojiText text={`Hi ${OK}`} customEmojis={fromJS([])} />
        </div>
      </Provider>,
    );

    expect(view.container.querySelector('img').getAttribute('alt')).toBe(OK);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: chain,
      });
    });

    expect(view.container.textContent).toContain(SPARKLE);
    expect(view.container.textContent).not.toContain('[sparkles]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: chain,
      });
    });

    expect(atRelease).toContain(SPARKLE);
    expect(atRelease).not.toContain('[sparkles]');
    expect(view.container.textContent).not.toContain('[sparkles]');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    view.unmount();
  });

  it('restores an ordinary photo alt without a second replacement', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);

    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <img src='/media/plain.jpg' alt={`plain ${OK}`} />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: chain,
      });
    });

    expect(view.container.querySelector('img').getAttribute('alt')).toBe(`plain ${OK}`);
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    view.unmount();
  });

  it('releases a card title from the source written during suppression', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let released = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) === '4' && store.getState().getIn(['emojiMutes', 'display']) === 'apply') {
        released = document.querySelector('.card-title').textContent;
      }
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <ConnectedTitle />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });
    act(() => {
      store.dispatch({ type: 'SET_TITLE', title: `Hi ${SMILE}` });
    });
    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [{
          id: 'm1',
          revision: '4',
          emoji: { kind: 'unicode', native: OK },
          replacement: '[ok]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(released).toBe(`Hi ${SMILE}`);
    expect(view.container.querySelector('.card-title').textContent).toBe(`Hi ${SMILE}`);
    view.unmount();
  });

  it('keeps the later embed paragraph when an earlier one projects away', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);

    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <div className='status-card-video' />
        </div>
      </Provider>,
    );
    const embed = view.container.querySelector('.status-card-video');

    embed.innerHTML = `<p></p><p>${OK}</p>`;
    bindEmojiMuteHtmlSources(embed, `<p>${OK}</p><p>${SPARKLE}</p>`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [
          {
            id: 'm1',
            revision: '3',
            emoji: { kind: 'unicode', native: OK },
            replacement: '',
            effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
          },
          {
            id: 'm2',
            revision: '3',
            emoji: { kind: 'unicode', native: SPARKLE },
            replacement: OK,
            effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
          },
          {
            id: 'm3',
            revision: '3',
            emoji: { kind: 'unicode', native: OK },
            replacement: '[ok]',
            effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
          },
        ],
      });
    });

    expect(embed.querySelectorAll('p')[1].textContent).toBe(OK);
    expect(embed.textContent).not.toContain('[ok]');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    view.unmount();
  });

  it('clears a custom emoji link title before the suppress commit', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let titleAtSuppress = 'unset';

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) !== 'suppress') {
        return;
      }

      const link = document.querySelector('a.custom-emoji-url-link');

      titleAtSuppress = link ? link.getAttribute('title') : null;
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <a className='custom-emoji-url-link' href='https://remote.example/emoji/blob' title=':blob:' aria-label='blob at remote.example' data-shortcode='blob' data-domain='remote.example'>
            <img className='emojione custom-emoji' alt=':blob:' src='https://cdn.example/blob.svg' data-shortcode='blob' data-domain='remote.example' />
          </a>
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(titleAtSuppress).toBeNull();
    expect(view.container.querySelector('a').getAttribute('aria-label')).toBeNull();
    expect(view.container.querySelector('a').getAttribute('title')).toBeNull();
    view.unmount();
  });
});

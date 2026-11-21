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
import Emoji from 'mastodon/components/emoji';
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

  it('strips a remote custom emoji before React commits and restores it when it is not muted', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let beforeCommit = null;
    let capture = false;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (!capture) {
        return;
      }

      const img = document.querySelector('img.custom-emoji');
      beforeCommit = img ? {
        html: img.outerHTML,
        alt: img.getAttribute('alt'),
        title: img.getAttribute('title'),
        ariaLabel: img.getAttribute('aria-label'),
        src: img.getAttribute('src'),
        srcset: img.getAttribute('srcset'),
        original: img.getAttribute('data-original'),
        staticUrl: img.getAttribute('data-static'),
        shortcode: img.getAttribute('data-shortcode'),
        domain: img.getAttribute('data-domain'),
      } : null;
      capture = false;
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Emoji
            emoji='blob'
            hovered={false}
            url='https://cdn.example/remote.svg'
            static_url='https://cdn.example/remote.png'
            domain='remote.example'
          />
          <input aria-label='draft' defaultValue='keep :blob: https://cdn.example/remote.svg' />
        </div>
      </Provider>,
    );
    const draft = view.getByLabelText('draft');

    expect(view.container.querySelector('img').getAttribute('data-original')).toBe('https://cdn.example/remote.svg');
    expect(emojiMuteLiveDomProbe.scans).toBe(0);

    capture = true;
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(beforeCommit).not.toBeNull();
    expect(beforeCommit.html).not.toContain('cdn.example');
    expect(beforeCommit.html).not.toContain('blob');
    expect(beforeCommit.html).not.toContain('remote.example');
    expect(beforeCommit.src).toBeNull();
    expect(beforeCommit.srcset).toBeNull();
    expect(beforeCommit.original).toBeNull();
    expect(beforeCommit.staticUrl).toBeNull();
    expect(beforeCommit.shortcode).toBeNull();
    expect(beforeCommit.domain).toBeNull();
    expect(beforeCommit.title).toBeNull();
    expect(beforeCommit.ariaLabel).toBeNull();
    expect(beforeCommit.alt).toBe('◻');
    expect(draft.value).toBe('keep :blob: https://cdn.example/remote.svg');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({ type: 'UNRELATED' });
    });
    fireEvent.change(draft, { target: { value: 'keep :blob: https://cdn.example/remote.svg typed' } });

    expect(draft.value).toBe('keep :blob: https://cdn.example/remote.svg typed');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [],
      });
    });

    const restored = view.container.querySelector('img.custom-emoji');
    expect(restored.getAttribute('src')).toBe('https://cdn.example/remote.png');
    expect(restored.getAttribute('data-original')).toBe('https://cdn.example/remote.svg');
    expect(restored.getAttribute('data-static')).toBe('https://cdn.example/remote.png');
    expect(restored.getAttribute('data-shortcode')).toBe('blob');
    expect(restored.getAttribute('data-domain')).toBe('remote.example');
    expect(restored.hasAttribute('hidden')).toBe(false);
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('clears custom reaction chip labels before React commits and restores only the unmuted chip', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let beforeCommit = null;
    let capture = false;
    const customStatus = fromJS({
      id: 's2',
      account: 'a1',
      emoji_reactions: [
        { name: 'blob', count: 1, account_ids: ['2'], domain: 'remote.example', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png' },
        { name: 'star', count: 1, account_ids: ['2'], domain: 'other.example', url: 'https://cdn.example/star.svg', static_url: 'https://cdn.example/star.png' },
      ],
    });

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (!capture) {
        return;
      }

      const found = document.querySelectorAll('button.reactions-bar__item');
      beforeCommit = [];

      for (let index = 0; index < found.length; index += 1) {
        const button = found[index];
        beforeCommit.push({
          html: button.outerHTML,
          title: button.getAttribute('title'),
          name: button.getAttribute('data-emoji-reaction-name'),
          domain: button.getAttribute('data-emoji-reaction-domain'),
        });
      }
      capture = false;
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <EmojiReactionsBar status={customStatus} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
        </div>
      </Provider>,
    );

    expect(view.container.querySelector('button[title=":blob:"]')).not.toBeNull();
    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();
    expect(emojiMuteLiveDomProbe.scans).toBe(0);

    capture = true;
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(beforeCommit).toHaveLength(2);
    beforeCommit.forEach(button => {
      expect(button.title).toBeNull();
      expect(button.name).toBeNull();
      expect(button.domain).toBeNull();
      expect(button.html).not.toContain('blob');
      expect(button.html).not.toContain('star');
      expect(button.html).not.toContain('remote.example');
      expect(button.html).not.toContain('other.example');
      expect(button.html).not.toContain('cdn.example');
    });
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({ type: 'UNRELATED' });
    });
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [{
          id: 'm-blob',
          revision: '3',
          emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' },
          replacement: '[blob]',
          effects: { replace_in_text: true, hide_reactions: true, hide_in_picker: true, reject_reactions_to_own_posts: true },
        }],
      });
    });

    const restored = view.container.querySelector('button.reactions-bar__item');
    expect(restored.getAttribute('title')).toBe(':star:');
    expect(restored.getAttribute('data-emoji-reaction-name')).toBe('star');
    expect(restored.getAttribute('data-emoji-reaction-domain')).toBe('other.example');
    expect(view.container.querySelectorAll('button.reactions-bar__item')).toHaveLength(1);
    expect(view.container.innerHTML).not.toContain('blob');
    expect(view.container.innerHTML).not.toContain('remote.example');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('reprojects a success that lands before the suppress render commits', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let concealedSrc = 'unset';

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) !== 'suppress') {
        return;
      }

      const emoji = document.querySelector('img.custom-emoji');
      concealedSrc = emoji ? emoji.getAttribute('src') : null;
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <DisplayName account={account} />
          <Emoji emoji='star' hovered={false} url='https://cdn.example/star.svg' static_url='https://cdn.example/star.png' domain='other.example' />
          <input aria-label='draft' defaultValue={`keep ${OK}`} />
        </div>
      </Provider>,
    );
    const draft = view.getByLabelText('draft');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
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

    expect(concealedSrc).toBeNull();
    expect(view.container.innerHTML).toContain(`/emoji/${KEEP}.svg`);
    expect(view.container.innerHTML).not.toContain(`/emoji/${OK}.svg`);
    expect(view.container.innerHTML).toContain('[ok]');
    expect(view.container.querySelector('img.custom-emoji').getAttribute('src')).toBe('https://cdn.example/star.png');
    expect(view.container.querySelector('img.custom-emoji').getAttribute('data-original')).toBe('https://cdn.example/star.svg');
    expect(view.container.querySelector('img[src="/media/x.jpg"]').getAttribute('alt')).toBe(`photo ${OK}`);
    expect(draft.value).toBe(`keep ${OK}`);
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('keeps hide_reactions images concealed through a same-batch success and restores kept picture sources', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let atSuppress = null;
    let beforeCommit = null;
    const reactionStatus = fromJS({
      id: 's3',
      account: 'a1',
      emoji_reactions: [
        { name: 'blob', count: 1, account_ids: ['2'], domain: 'remote.example', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png' },
        { name: 'house', count: 1, account_ids: ['2'], custom_emoji_id: '42', url: 'https://cdn.example/house.svg', static_url: 'https://cdn.example/house.png' },
        { name: 'star', count: 1, account_ids: ['2'], domain: 'other.example', url: 'https://cdn.example/star.svg', static_url: 'https://cdn.example/star.png' },
      ],
    });
    const hideOnly = (emoji, id) => ({
      id,
      revision: '3',
      emoji,
      replacement: '',
      effects: { replace_in_text: false, hide_reactions: true, hide_in_picker: true, reject_reactions_to_own_posts: false },
    });

    const snapshot = () => {
      const chips = document.querySelectorAll('button.reactions-bar__item');

      return {
        blob: chips[0] && chips[0].querySelector('img'),
        house: chips[1] && chips[1].querySelector('img'),
        star: chips[2] && chips[2].querySelector('img'),
        blobButton: chips[0],
        houseButton: chips[1],
        starButton: chips[2],
        loose: document.querySelector('.loose-emoji img'),
        keptSource: document.querySelector('.kept-picture source'),
        mutedSource: document.querySelector('.muted-picture source'),
        mutedImg: document.querySelector('.muted-picture img'),
        draft: document.querySelector('input[aria-label="draft"]'),
      };
    };

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const display = store.getState().getIn(['emojiMutes', 'display']);
      const shot = snapshot();

      if (display === 'suppress') {
        atSuppress = {
          blobSrc: shot.blob && shot.blob.getAttribute('src'),
          houseSrc: shot.house && shot.house.getAttribute('src'),
          looseSrc: shot.loose && shot.loose.getAttribute('src'),
          keptSourceSrc: shot.keptSource && shot.keptSource.getAttribute('src'),
          mutedSourceSrc: shot.mutedSource && shot.mutedSource.getAttribute('src'),
        };
      }

      if (display === 'apply' && atSuppress) {
        beforeCommit = {
          blobSrc: shot.blob && shot.blob.getAttribute('src'),
          blobOriginal: shot.blob && shot.blob.getAttribute('data-original'),
          blobAlt: shot.blob && shot.blob.getAttribute('alt'),
          houseSrc: shot.house && shot.house.getAttribute('src'),
          houseOriginal: shot.house && shot.house.getAttribute('data-original'),
          blobName: shot.blobButton && shot.blobButton.getAttribute('data-emoji-reaction-name'),
          blobShortcode: shot.blobButton && shot.blobButton.getAttribute('data-emoji-shortcode'),
          houseId: shot.houseButton && shot.houseButton.getAttribute('data-emoji-custom-emoji-id'),
          houseTitle: shot.houseButton && shot.houseButton.getAttribute('title'),
          starSrc: shot.star && shot.star.getAttribute('src'),
          starShortcode: shot.starButton && shot.starButton.getAttribute('data-emoji-shortcode'),
          starTitle: shot.starButton && shot.starButton.getAttribute('title'),
          looseSrc: shot.loose && shot.loose.getAttribute('src'),
          looseOriginal: shot.loose && shot.loose.getAttribute('data-original'),
          keptSourceSrc: shot.keptSource && shot.keptSource.getAttribute('src'),
          keptSourceSet: shot.keptSource && shot.keptSource.getAttribute('srcset'),
          mutedSourceSrc: shot.mutedSource && shot.mutedSource.getAttribute('src'),
          mutedSourceSet: shot.mutedSource && shot.mutedSource.getAttribute('srcset'),
          mutedImgSrc: shot.mutedImg && shot.mutedImg.getAttribute('src'),
          draft: shot.draft && shot.draft.value,
        };
      }
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <EmojiReactionsBar status={reactionStatus} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
          <div className='loose-emoji'>
            <Emoji emoji='blob' hovered={false} url='https://cdn.example/blob.svg' static_url='https://cdn.example/blob.png' domain='remote.example' />
          </div>
          <picture className='kept-picture'>
            <source src={`/emoji/${KEEP}.svg`} srcSet={`/emoji/${KEEP}.svg 2x`} />
            <img className='emojione' alt={KEEP} title={KEEP} src={`/emoji/${KEEP}.svg`} />
          </picture>
          <picture className='muted-picture'>
            <source src={`/emoji/${OK}.svg`} srcSet={`/emoji/${OK}.svg 2x`} />
            <img className='emojione' alt={OK} title={OK} src={`/emoji/${OK}.svg`} />
          </picture>
          <input aria-label='draft' defaultValue='draft stays' />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [
          hideOnly({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, 'm-remote'),
          hideOnly({ kind: 'custom', scope: 'local', custom_emoji_id: '42', shortcode: 'house' }, 'm-local'),
          {
            id: 'm-ok',
            revision: '3',
            emoji: { kind: 'unicode', native: OK },
            replacement: '[ok]',
            effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
          },
        ],
      });
    });

    expect(atSuppress.blobSrc).toBeNull();
    expect(atSuppress.houseSrc).toBeNull();
    expect(atSuppress.looseSrc).toBeNull();
    expect(atSuppress.keptSourceSrc).toBeNull();
    expect(atSuppress.mutedSourceSrc).toBeNull();

    expect(beforeCommit.blobSrc).toBeNull();
    expect(beforeCommit.blobOriginal).toBeNull();
    expect(beforeCommit.blobAlt).toBe('◻');
    expect(beforeCommit.blobName).toBeNull();
    expect(beforeCommit.blobShortcode).toBeNull();
    expect(beforeCommit.houseSrc).toBeNull();
    expect(beforeCommit.houseOriginal).toBeNull();
    expect(beforeCommit.houseId).toBeNull();
    expect(beforeCommit.houseTitle).toBeNull();
    expect(beforeCommit.starSrc).toBe('https://cdn.example/star.png');
    expect(beforeCommit.starShortcode).toBe('star');
    expect(beforeCommit.starTitle).toBe(':star:');
    expect(beforeCommit.looseSrc).toBe('https://cdn.example/blob.png');
    expect(beforeCommit.looseOriginal).toBe('https://cdn.example/blob.svg');
    expect(beforeCommit.keptSourceSrc).toBe(`/emoji/${KEEP}.svg`);
    expect(beforeCommit.keptSourceSet).toBe(`/emoji/${KEEP}.svg 2x`);
    expect(beforeCommit.mutedSourceSrc).toBeNull();
    expect(beforeCommit.mutedSourceSet).toBeNull();
    expect(beforeCommit.mutedImgSrc).toBeNull();
    expect(beforeCommit.draft).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    expect(view.container.querySelector('button[title=":blob:"]')).toBeNull();
    expect(view.container.querySelector('button[title=":house:"]')).toBeNull();
    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();
    expect(view.container.querySelector('.loose-emoji img').getAttribute('src')).toBe('https://cdn.example/blob.png');
    expect(view.container.querySelector('.kept-picture source').getAttribute('src')).toBe(`/emoji/${KEEP}.svg`);
    expect(view.container.querySelector('.muted-picture source').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.muted-picture source').getAttribute('srcset')).toBeNull();
    expect(view.getByLabelText('draft').value).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });
});

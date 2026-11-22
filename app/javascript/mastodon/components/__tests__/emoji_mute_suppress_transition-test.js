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
import { attachInlineEmojiMenus } from 'mastodon/features/emoji/emoji_actions/inline_emoji';
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

  if (action.type === 'SHOW_KEEP_RULES') {
    return state
      .setIn(['emojiMutes', 'display'], 'show')
      .setIn(['emojiMutes', 'revision'], '3')
      .setIn(['emojiMutes', 'rules'], fromJS(action.rules || []));
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

  it('keeps a card title React committed during suppression and projects classless emoji urls from the snapshot', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let beforeCommit = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) !== 'apply' || !document.querySelector('.classless-muted')) {
        return;
      }

      const muted = document.querySelector('.classless-muted');
      const kept = document.querySelector('.classless-kept');
      beforeCommit = {
        mutedSrc: muted.getAttribute('src'),
        mutedAlt: muted.getAttribute('alt'),
        keptSrc: kept.getAttribute('src'),
        keptAlt: kept.getAttribute('alt'),
        title: document.querySelector('.status-card__title').textContent,
        titleAttr: document.querySelector('.status-card__title').getAttribute('title'),
        label: document.querySelector('.status-card__title').getAttribute('aria-label'),
      };
    });

    const THUMBS = '👍';
    const CardTitle = ({ text }) => (
      <strong className='status-card__title' title={text} aria-label={text}>{text}</strong>
    );
    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CardTitle text={`Hello ${OK}`} />
          <img className='classless-muted' src='/emoji/1f44d.svg' alt={THUMBS} />
          <img className='classless-kept' src='/emoji/2728.svg' alt={KEEP} />
          <input aria-label='draft' defaultValue='draft stays' />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    view.rerender(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CardTitle text='Updated' />
          <img className='classless-muted' src='/emoji/1f44d.svg' alt={THUMBS} />
          <img className='classless-kept' src='/emoji/2728.svg' alt={KEEP} />
          <input aria-label='draft' defaultValue='draft stays' />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [{
          id: 'm-thumbs',
          revision: '3',
          emoji: { kind: 'unicode', native: THUMBS },
          replacement: '[up]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(beforeCommit.title).toBe('Updated');
    expect(beforeCommit.titleAttr).toBe('Updated');
    expect(beforeCommit.label).toBe('Updated');
    expect(beforeCommit.mutedSrc).toBeNull();
    expect(beforeCommit.mutedAlt).not.toBe(THUMBS);
    expect(beforeCommit.keptSrc).toBe('/emoji/2728.svg');
    expect(beforeCommit.keptAlt).toBe(KEEP);
    expect(view.container.querySelector('.status-card__title').textContent).toBe('Updated');
    expect(view.container.querySelector('.status-card__title').getAttribute('title')).toBe('Updated');
    expect(view.container.querySelector('.status-card__title').getAttribute('aria-label')).toBe('Updated');
    expect(view.container.querySelector('.classless-muted').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.classless-kept').getAttribute('src')).toBe('/emoji/2728.svg');
    expect(view.getByLabelText('draft').value).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('projects classless emoji urls from the recorded src in the same act', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let atSuppress = null;
    let beforeCommit = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const display = store.getState().getIn(['emojiMutes', 'display']);
      const muted = document.querySelector('.classless-muted');
      const kept = document.querySelector('.classless-kept');
      const mutedSource = document.querySelector('.classless-muted-picture source');
      const keptSource = document.querySelector('.classless-kept-picture source');

      if (!muted) {
        return;
      }

      const shot = {
        mutedSrc: muted.getAttribute('src'),
        mutedAlt: muted.getAttribute('alt'),
        keptSrc: kept.getAttribute('src'),
        keptAlt: kept.getAttribute('alt'),
        mutedSourceSrc: mutedSource.getAttribute('src'),
        mutedSourceSet: mutedSource.getAttribute('srcset'),
        keptSourceSrc: keptSource.getAttribute('src'),
        keptSourceSet: keptSource.getAttribute('srcset'),
        draft: document.querySelector('input').value,
      };

      if (display === 'suppress') {
        atSuppress = shot;
      }

      if (display === 'apply' && store.getState().getIn(['emojiMutes', 'revision']) === '3') {
        beforeCommit = shot;
      }
    });

    const THUMBS = '👍';
    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <img className='classless-muted' src='/emoji/1f44d.svg' alt={THUMBS} />
          <img className='classless-kept' src='/emoji/2728.svg' alt={KEEP} />
          <picture className='classless-muted-picture'>
            <source src='/emoji/1f44d.svg' srcSet='/emoji/1f44d.svg 2x' />
            <img src='/emoji/1f44d.svg' alt={THUMBS} />
          </picture>
          <picture className='classless-kept-picture'>
            <source src='/emoji/2728.svg' srcSet='/emoji/2728.svg 2x' />
            <img src='/emoji/2728.svg' alt={KEEP} />
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
        mutes: [{
          id: 'm-thumbs',
          revision: '3',
          emoji: { kind: 'unicode', native: THUMBS },
          replacement: '[up]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(atSuppress.mutedSrc).toBeNull();
    expect(atSuppress.keptSrc).toBeNull();
    expect(atSuppress.mutedSourceSrc).toBeNull();
    expect(atSuppress.keptSourceSrc).toBeNull();
    expect(beforeCommit.mutedSrc).toBeNull();
    expect(beforeCommit.mutedAlt).toBe('[up]');
    expect(beforeCommit.keptSrc).toBe('/emoji/2728.svg');
    expect(beforeCommit.keptAlt).toBe(KEEP);
    expect(beforeCommit.mutedSourceSrc).toBeNull();
    expect(beforeCommit.mutedSourceSet).toBeNull();
    expect(beforeCommit.keptSourceSrc).toBe('/emoji/2728.svg');
    expect(beforeCommit.keptSourceSet).toBe('/emoji/2728.svg 2x');
    expect(beforeCommit.draft).toBe('draft stays');
    expect(view.container.querySelector('.classless-muted').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.classless-muted').getAttribute('alt')).toBe('[up]');
    expect(view.container.querySelector('.classless-kept').getAttribute('src')).toBe('/emoji/2728.svg');
    expect(view.container.querySelector('.classless-muted-picture source').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.classless-muted-picture source').getAttribute('srcset')).toBeNull();
    expect(view.container.querySelector('.classless-kept-picture source').getAttribute('src')).toBe('/emoji/2728.svg');
    expect(view.container.querySelector('.classless-kept-picture img').getAttribute('src')).toBe('/emoji/2728.svg');
    expect(view.getByLabelText('draft').value).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('restores reaction images that hide_reactions allows and keeps replace_in_text on body emoji', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let beforeCommit = null;
    const DOWN = '👎';
    const reactionStatus = fromJS({
      id: 's4',
      account: 'a1',
      emoji_reactions: [
        { name: 'blob', count: 1, account_ids: ['2'], domain: 'remote.example', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png' },
        { name: 'house', count: 1, account_ids: ['2'], custom_emoji_id: '42', url: 'https://cdn.example/house.svg', static_url: 'https://cdn.example/house.png' },
      ],
    });
    const rule = (emoji, id, hide) => ({
      id,
      revision: '3',
      emoji,
      replacement: '[muted]',
      effects: { replace_in_text: true, hide_reactions: hide, hide_in_picker: false, reject_reactions_to_own_posts: false },
    });

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) !== 'apply' || store.getState().getIn(['emojiMutes', 'revision']) !== '3') {
        return;
      }

      const allowed = document.querySelector('.allowed-unicode img');
      const hidden = document.querySelector('.hidden-unicode img');
      beforeCommit = {
        allowedSrc: allowed.getAttribute('src'),
        allowedAlt: allowed.getAttribute('alt'),
        allowedHidden: allowed.hasAttribute('hidden'),
        allowedSource: document.querySelector('.allowed-unicode source').getAttribute('src'),
        hiddenSrc: hidden.getAttribute('src'),
        hiddenAlt: hidden.getAttribute('alt'),
        hiddenSource: document.querySelector('.hidden-unicode source').getAttribute('src'),
        blobSrc: document.querySelector('button[data-emoji-reaction-name="blob"] img').getAttribute('src'),
        houseSrc: document.querySelector('button[data-emoji-reaction-name="house"] img').getAttribute('src'),
        bodySrc: document.querySelector('.body-ok').getAttribute('src'),
        bodyAlt: document.querySelector('.body-ok').getAttribute('alt'),
      };
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <EmojiReactionsBar status={reactionStatus} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
          <button type='button' className='reactions-bar__item allowed-unicode' data-emoji-reaction-name={OK} data-emoji-native={OK}>
            <picture>
              <source src={`/emoji/${OK}.svg`} srcSet={`/emoji/${OK}.svg 2x`} />
              <img className='emojione' alt={OK} title={OK} src={`/emoji/${OK}.svg`} />
            </picture>
          </button>
          <button type='button' className='reactions-bar__item hidden-unicode' data-emoji-reaction-name={DOWN} data-emoji-native={DOWN}>
            <picture>
              <source src='/emoji/1f44e.svg' srcSet='/emoji/1f44e.svg 2x' />
              <img className='emojione' alt={DOWN} src='/emoji/1f44e.svg' />
            </picture>
          </button>
          <img className='emojione body-ok' alt={OK} title={OK} src={`/emoji/${OK}.svg`} />
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
          rule({ kind: 'unicode', native: OK }, 'm-ok', false),
          rule({ kind: 'unicode', native: DOWN }, 'm-down', true),
          rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, 'm-blob', false),
          rule({ kind: 'custom', scope: 'local', custom_emoji_id: '42', shortcode: 'house' }, 'm-house', false),
        ],
      });
    });

    expect(beforeCommit.allowedSrc).toBe(`/emoji/${OK}.svg`);
    expect(beforeCommit.allowedAlt).toBe(OK);
    expect(beforeCommit.allowedHidden).toBe(false);
    expect(beforeCommit.allowedSource).toBe(`/emoji/${OK}.svg`);
    expect(beforeCommit.hiddenSrc).toBeNull();
    expect(beforeCommit.hiddenAlt).not.toBe(DOWN);
    expect(beforeCommit.hiddenSource).toBeNull();
    expect(beforeCommit.blobSrc).toBe('https://cdn.example/blob.png');
    expect(beforeCommit.houseSrc).toBe('https://cdn.example/house.png');
    expect(beforeCommit.bodySrc).toBeNull();
    expect(beforeCommit.bodyAlt).toBe('[muted]');
    expect(view.container.querySelector('.allowed-unicode img').getAttribute('src')).toBe(`/emoji/${OK}.svg`);
    expect(view.container.querySelector('.allowed-unicode img').getAttribute('alt')).toBe(OK);
    expect(view.container.querySelector('.hidden-unicode img').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.hidden-unicode source').getAttribute('src')).toBeNull();
    expect(view.container.querySelector('.body-ok').getAttribute('src')).toBeNull();
    expect(view.getByLabelText('draft').value).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('keeps a reaction alt React committed during suppression and still restores its url', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const Glyph = ({ alt }) => (
      <button type='button' className='reactions-bar__item' data-emoji-reaction-name={OK} data-emoji-native={OK}>
        <img className='emojione' alt={alt} src={`/emoji/${OK}.svg`} />
      </button>
    );

    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Glyph alt={OK} />
          <input aria-label='draft' defaultValue='draft stays' />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    view.rerender(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Glyph alt='Updated' />
          <input aria-label='draft' defaultValue='draft stays' />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [{
          id: 'm-ok',
          revision: '3',
          emoji: { kind: 'unicode', native: OK },
          replacement: '[muted]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(view.container.querySelector('img').getAttribute('alt')).toBe('Updated');
    expect(view.container.querySelector('img').getAttribute('src')).toBe(`/emoji/${OK}.svg`);
    expect(view.container.querySelector('img').hasAttribute('hidden')).toBe(false);
    expect(view.getByLabelText('draft').value).toBe('draft stays');
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    expect(() => view.unmount()).not.toThrow();
  });

  it('projects a menu-decorated body and display-name emoji instead of treating it as a reaction', () => {
    const blobImg = '<img class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/blob.png" data-shortcode="blob" data-domain="remote.example" data-original="https://cdn.example/blob.svg" data-static="https://cdn.example/blob.png">';
    const displayAccount = fromJS({ id: 'a9', acct: 'alice', display_name_html: blobImg });

    class InlineBody extends React.PureComponent {

      setRef = node => {
        this.node = node;
      };

      componentDidMount () {
        this.detach = attachInlineEmojiMenus(this.node, { source: 'inline_status', statusId: 's9' });
      }

      componentWillUnmount () {
        this.detach?.();
      }

      render () {
        return <div className='status__content__text' ref={this.setRef} dangerouslySetInnerHTML={{ __html: `<p>Hello ${blobImg} there</p>` }} />;
      }

    }

    const rule = (replaceInText, hideReactions) => ({
      id: 'm-blob',
      revision: '3',
      emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' },
      replacement: '[blob]',
      effects: {
        replace_in_text: replaceInText,
        hide_reactions: hideReactions,
        hide_in_picker: false,
        reject_reactions_to_own_posts: false,
      },
    });

    const run = (mutes, show) => {
      const guard = createUnverifiedEmojiGuard();
      const store = createStore(reducer);
      let beforeCommit = null;

      store.subscribe(() => guard(store.getState()));
      store.subscribe(() => {
        if (store.getState().getIn(['emojiMutes', 'revision']) !== '3') {
          return;
        }

        const imgs = document.querySelectorAll('img.custom-emoji');
        const shots = [];

        for (let index = 0; index < imgs.length; index += 1) {
          const img = imgs[index];

          shots.push({
            src: img.getAttribute('src'),
            alt: img.getAttribute('alt'),
            title: img.getAttribute('title'),
            hidden: img.hasAttribute('hidden'),
            ariaHidden: img.getAttribute('aria-hidden'),
            shortcode: img.getAttribute('data-emoji-shortcode'),
            domain: img.getAttribute('data-emoji-domain'),
          });
        }

        beforeCommit = shots;
      });

      const view = render(
        <Provider store={store}>
          <div className='emoji-mutes-privacy-portal'>
            <DisplayName account={displayAccount} />
            <InlineBody />
          </div>
        </Provider>,
      );
      const painted = view.container.querySelectorAll('img.custom-emoji');

      expect(painted.length).toBe(2);
      painted.forEach(img => {
        expect(img.getAttribute('data-emoji-shortcode')).toBe('blob');
        expect(img.getAttribute('data-emoji-domain')).toBe('remote.example');
      });

      act(() => {
        store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
        if (show) {
          store.dispatch({ type: 'SHOW_KEEP_RULES', rules: mutes });
        } else {
          store.dispatch({
            type: EMOJI_MUTES_APPLY,
            revision: '3',
            availability: 'enabled',
            mutes,
          });
        }
      });

      return { view, beforeCommit };
    };

    [
      [true, false],
      [true, true],
      [false, false],
      [false, true],
    ].forEach(([replaceInText, hideReactions]) => {
      const { view, beforeCommit } = run([rule(replaceInText, hideReactions)], false);

      expect(beforeCommit).toHaveLength(2);
      beforeCommit.forEach(shot => {
        if (replaceInText) {
          expect(shot.src).toBeNull();
          expect(shot.alt).toBe('[blob]');
          expect(shot.title).toBeNull();
          expect(shot.hidden).toBe(true);
          expect(shot.ariaHidden).toBe('true');
          expect(shot.shortcode).toBeNull();
          expect(shot.domain).toBeNull();
        } else {
          expect(shot.src).toBe('https://cdn.example/blob.png');
          expect(shot.alt).toBe(':blob:');
          expect(shot.title).toBe('blob');
          expect(shot.hidden).toBe(false);
          expect(shot.ariaHidden).toBeNull();
          expect(shot.shortcode).toBe('blob');
          expect(shot.domain).toBe('remote.example');
        }
      });

      if (replaceInText) {
        expect(view.container.innerHTML).not.toContain('https://cdn.example/blob.png');
        expect(view.container.textContent).toContain('[blob]');
      } else {
        expect(view.container.querySelectorAll('img.custom-emoji[src="https://cdn.example/blob.png"]')).toHaveLength(2);
      }

      view.unmount();
    });

    const shown = run([rule(true, true)], true);

    expect(shown.beforeCommit).toHaveLength(2);
    shown.beforeCommit.forEach(shot => {
      expect(shot.src).toBe('https://cdn.example/blob.png');
      expect(shot.hidden).toBe(false);
      expect(shot.ariaHidden).toBeNull();
    });
    expect(shown.view.container.querySelectorAll('img.custom-emoji[src="https://cdn.example/blob.png"]')).toHaveLength(2);
    shown.view.unmount();
  });
});

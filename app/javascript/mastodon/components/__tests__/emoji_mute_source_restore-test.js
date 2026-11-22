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

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import CustomEmojiText from 'mastodon/components/custom_emoji_text';
import { createUnverifiedEmojiGuard, emojiMuteLiveDomProbe, resetEmojiMuteLiveDomProbe } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { bindEmojiMuteElementSource, bindEmojiMuteHtmlSources } from 'mastodon/features/emoji/emoji_mute_sources';
import { emojiMuteTextIndexFromState, presentEmojiMutePlain, replaceEmojiInDisplayHtml } from 'mastodon/features/emoji/emoji_mute_text';
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

  it('restores a replaced custom emoji from its original HTML, not the shortcode', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const blob = fromJS([{
      id: '10',
      shortcode: 'blob',
      url: 'https://cdn.example/blob.svg',
      static_url: 'https://cdn.example/blob.png',
      domain: null,
    }]);
    const rule = {
      id: 'mb',
      revision: '2',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: SPARKLE,
      effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
    };
    let atSuppress = null;
    let atRelease = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const display = store.getState().getIn(['emojiMutes', 'display']);
      const revision = store.getState().getIn(['emojiMutes', 'revision']);
      const text = document.querySelector('.emoji-mutes-privacy-portal').textContent;

      if (display === 'suppress' && revision === '3' && !atSuppress) {
        atSuppress = text;
      }

      if (display === 'apply' && revision === '4') {
        atRelease = text;
      }
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CustomEmojiText text='Hi :blob:' customEmojis={blob} />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule],
      });
    });

    const shown = view.container.querySelector('.emoji-mutes-privacy-portal span');

    expect(shown.childNodes).toHaveLength(1);
    expect(shown.firstChild.nodeType).toBe(Node.TEXT_NODE);
    expect(shown.textContent).toBe(`Hi ${SPARKLE}`);
    expect(shown.querySelector('img')).toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [{ ...rule, revision: '4' }],
      });
    });

    expect(atSuppress).toBe(`Hi ${'\u25FB'}`);
    expect(atSuppress).not.toContain(':blob:');
    expect(atRelease).toBe(`Hi ${SPARKLE}`);
    expect(atRelease).not.toContain(':blob:');
    expect(shown.textContent).toBe(`Hi ${SPARKLE}`);
    expect(shown.querySelector('img')).toBeNull();
    expect(emojiMuteLiveDomProbe.scans).toBe(1);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(shown.querySelector('img.custom-emoji')).not.toBeNull();
    expect(Array.from(shown.childNodes).filter(node => node.nodeType === Node.TEXT_NODE).map(node => node.nodeValue).join('')).not.toContain(':blob:');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '5',
        availability: 'enabled',
        mutes: [{ ...rule, revision: '5' }],
      });
    });
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(shown.querySelector('img.custom-emoji')).not.toBeNull();
    expect(Array.from(shown.childNodes).filter(node => node.nodeType === Node.TEXT_NODE).map(node => node.nodeValue).join('')).not.toContain(':blob:');
    view.unmount();
  });

  it('keeps a collapsed text-and-image source when they become one text node', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const rule = {
      id: 'mb',
      revision: '4',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: SPARKLE,
      effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
    };

    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <div className='merged' />
        </div>
      </Provider>,
    );
    const merged = view.container.querySelector('.merged');
    const image = '<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="10" src="https://cdn.example/blob.svg">';

    merged.innerHTML = `Hi ${SPARKLE}`;
    bindEmojiMuteHtmlSources(merged, `Hi ${image}`);
    expect(merged.childNodes).toHaveLength(1);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [rule],
      });
    });

    expect(merged.textContent).toBe(`Hi ${SPARKLE}`);
    expect(merged.textContent).not.toContain(':blob:');
    expect(merged.querySelector('img')).toBeNull();
    view.unmount();
  });

  it('restores only the replaced emoji when another emoji image stays', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const emojis = fromJS([
      { id: '10', shortcode: 'blob', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png', domain: null },
      { id: '11', shortcode: 'other', url: 'https://cdn.example/other.svg', static_url: 'https://cdn.example/other.png', domain: null },
    ]);
    const rule = {
      id: 'mb',
      revision: '2',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: SPARKLE,
      effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
    };
    let atSuppress = null;
    let atRelease = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const root = document.querySelector('.emoji-mutes-privacy-portal');
      const display = store.getState().getIn(['emojiMutes', 'display']);
      const revision = store.getState().getIn(['emojiMutes', 'revision']);
      const snap = {
        text: root.textContent,
        html: root.innerHTML,
      };

      if (display === 'suppress' && revision === '3' && !atSuppress) {
        atSuppress = snap;
      }

      if (display === 'apply' && revision === '4') {
        atRelease = snap;
      }
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CustomEmojiText text='Hi :blob: :other:' customEmojis={emojis} />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule],
      });
    });

    const shown = view.container.querySelector('.emoji-mutes-privacy-portal span');
    const kept = () => shown.querySelector('img');

    expect(shown.firstChild.nodeType).toBe(Node.TEXT_NODE);
    expect(shown.firstChild.nodeValue).toContain(SPARKLE);
    expect(shown.firstChild.nodeValue).not.toContain(':blob:');
    expect(shown.firstChild.nodeValue).not.toContain(':other:');
    expect(kept().getAttribute('data-emoji-id')).toBe('11');
    expect(kept().getAttribute('src')).toBe('https://cdn.example/other.png');
    expect(shown.querySelectorAll('img')).toHaveLength(1);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [{ ...rule, revision: '4' }],
      });
    });

    expect(atSuppress.text).toContain('\u25FB');
    expect(atSuppress.text).not.toContain(SPARKLE);
    expect(atSuppress.html).not.toContain('cdn.example/blob');
    expect(atSuppress.html).not.toContain('cdn.example/other');
    expect(atSuppress.html).not.toContain(':blob:');
    expect(atSuppress.html).not.toContain(':other:');
    expect(atRelease.text).toContain(`Hi ${SPARKLE}`);
    expect(atRelease.text).not.toContain(':blob:');
    expect(atRelease.text).not.toContain(':other:');
    expect(atRelease.html).toContain('cdn.example/other');
    expect(atRelease.html).not.toContain('cdn.example/blob');
    expect(shown.firstChild.nodeValue).toContain(SPARKLE);
    expect(kept().getAttribute('src')).toBe('https://cdn.example/other.png');
    expect(shown.querySelectorAll('img')).toHaveLength(1);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(shown.querySelectorAll('img.custom-emoji')).toHaveLength(2);
    expect(shown.innerHTML).toContain('cdn.example/blob');
    expect(shown.innerHTML).toContain('cdn.example/other');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '5',
        availability: 'enabled',
        mutes: [{ ...rule, revision: '5' }],
      });
    });
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(shown.querySelectorAll('img.custom-emoji')).toHaveLength(2);
    expect(emojiMuteLiveDomProbe.scans).toBe(1);
    view.unmount();
  });

  it('does not copy a removed leading emoji onto the image that stays', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const emojis = fromJS([
      { id: '10', shortcode: 'blob', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png', domain: null },
      { id: '11', shortcode: 'other', url: 'https://cdn.example/other.svg', static_url: 'https://cdn.example/other.png', domain: null },
    ]);
    const rule = {
      id: 'mb',
      revision: '2',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: '',
      effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
    };
    let atRelease = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) !== '4' || store.getState().getIn(['emojiMutes', 'display']) !== 'apply') {
        return;
      }

      const image = document.querySelector('.emoji-mutes-privacy-portal img');

      atRelease = image ? {
        src: image.getAttribute('src'),
        alt: image.getAttribute('alt'),
        title: image.getAttribute('title'),
      } : null;
    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <CustomEmojiText text=':blob::other:' customEmojis={emojis} />
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule],
      });
    });

    const image = () => view.container.querySelector('.emoji-mutes-privacy-portal img');

    expect(view.container.querySelectorAll('img')).toHaveLength(1);
    expect(image().getAttribute('data-emoji-id')).toBe('11');
    expect(image().getAttribute('alt')).toBe(':other:');
    expect(image().getAttribute('title')).toBe('other');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [{ ...rule, revision: '4' }],
      });
    });

    expect(atRelease).toEqual({
      src: 'https://cdn.example/other.png',
      alt: ':other:',
      title: 'other',
    });
    expect(image().getAttribute('src')).toBe('https://cdn.example/other.png');
    expect(image().getAttribute('alt')).toBe(':other:');
    expect(image().getAttribute('title')).toBe('other');
    expect(image().getAttribute('alt')).not.toBe(':blob:');
    view.unmount();
  });

  it('restores a mixed embed text node without taking the surviving image alt', () => {
    resetEmojiMuteLiveDomProbe();
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    const rule = {
      id: 'mb',
      revision: '4',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: SPARKLE,
      effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
    };
    const blob = '<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="10" src="https://cdn.example/blob.svg">';
    const other = '<img class="emojione custom-emoji" alt=":other:" data-shortcode="other" data-domain="" data-emoji-id="11" src="https://cdn.example/other.svg">';

    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <div className='status-card-video' />
        </div>
      </Provider>,
    );
    const embed = view.container.querySelector('.status-card-video');

    embed.innerHTML = `<p></p><p>Hi ${SPARKLE} ${other}</p>`;
    bindEmojiMuteHtmlSources(embed, `<p>${OK}</p><p>Hi ${blob} ${other}</p>`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [rule],
      });
    });

    const paragraph = embed.querySelectorAll('p')[1];

    expect(paragraph.firstChild.nodeValue).toContain(`Hi ${SPARKLE}`);
    expect(paragraph.firstChild.nodeValue).not.toContain(':other:');
    expect(paragraph.firstChild.nodeValue).not.toContain(':blob:');
    expect(paragraph.querySelector('img').getAttribute('src')).toBe('https://cdn.example/other.svg');
    expect(paragraph.querySelectorAll('img')).toHaveLength(1);
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

  it('keeps an HTML photo alt and applies a gallery description once', () => {
    const thumb = '👍';
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rules = [{
      id: 'up',
      revision: '1',
      emoji: { kind: 'unicode', native: thumb },
      replacement: '[up]',
      effects,
    }];
    const store = createStore(reducer, fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules,
        availability: 'enabled',
        display: 'apply',
      },
      title: '',
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));

    const PhotoAndGallery = connect(state => ({
      index: emojiMuteTextIndexFromState(state),
    }))(class BoundMedia extends React.Component {

      componentDidMount () {
        this.bind();
      }

      componentDidUpdate () {
        this.bind();
      }

      bind () {
        bindEmojiMuteHtmlSources(this.photo, `<img alt="photo ${thumb}" src="/photos/1.jpg">`);
        bindEmojiMuteElementSource(this.gallery, `photo ${thumb}`);
      }

      setPhoto = node => {
        this.photo = node;
      }

      setGallery = node => {
        this.gallery = node;
      }

      render () {
        const description = presentEmojiMutePlain(`photo ${thumb}`, this.props.index);

        return (
          <div>
            <div ref={this.setPhoto} dangerouslySetInnerHTML={{ __html: `<img alt="photo ${thumb}" src="/photos/1.jpg">` }} />
            <img alt={description} title={description} src='/photos/2.jpg' ref={this.setGallery} />
          </div>
        );
      }

    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <PhotoAndGallery />
        </div>
      </Provider>,
    );
    const photo = view.container.querySelector('img[src="/photos/1.jpg"]');
    const gallery = view.container.querySelector('img[src="/photos/2.jpg"]');

    expect(photo.getAttribute('alt')).toBe(`photo ${thumb}`);
    expect(gallery.getAttribute('alt')).toBe('photo [up]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: rules,
      });
    });

    expect(photo.getAttribute('alt')).toBe(`photo ${thumb}`);
    expect(gallery.getAttribute('alt')).toBe('photo [up]');
    expect(gallery.getAttribute('title')).toBe('photo [up]');
    view.unmount();
  });

  it('does not give a removed classless emoji to the next image', () => {
    const thumb = '👍';
    const spark = '✨';
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rules = [{
      id: 'up',
      revision: '1',
      emoji: { kind: 'unicode', native: thumb },
      replacement: '',
      effects,
    }];
    const original = `<img alt="${thumb}" src="/emoji/1f44d.svg"><img alt="${spark}" src="/emoji/2728.svg">`;
    const store = createStore(reducer, fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules,
        availability: 'enabled',
        display: 'apply',
      },
      title: '',
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));

    const Block = connect(state => ({
      index: emojiMuteTextIndexFromState(state),
    }))(class HtmlBlock extends React.Component {

      componentDidMount () {
        bindEmojiMuteHtmlSources(this.node, original);
      }

      componentDidUpdate () {
        bindEmojiMuteHtmlSources(this.node, original);
      }

      setNode = node => {
        this.node = node;
      }

      render () {
        return (
          <div
            ref={this.setNode}
            dangerouslySetInnerHTML={{ __html: replaceEmojiInDisplayHtml(original, this.props.index) }}
          />
        );
      }

    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Block />
        </div>
      </Provider>,
    );
    const image = view.container.querySelector('img');

    expect(image.getAttribute('src')).toBe('/emoji/2728.svg');
    expect(image.getAttribute('alt')).toBe(spark);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: rules,
      });
    });

    expect(view.container.querySelector('img').getAttribute('src')).toBe('/emoji/2728.svg');
    expect(view.container.querySelector('img').getAttribute('alt')).toBe(spark);
    expect(view.container.querySelector('img').getAttribute('src')).not.toBe('/emoji/1f44d.svg');
    view.unmount();
  });

  it('keeps text after a replaced picture', () => {
    const thumb = '👍';
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rules = [
      { id: 'up', revision: '1', emoji: { kind: 'unicode', native: thumb }, replacement: SPARKLE, effects },
      { id: 'spark', revision: '1', emoji: { kind: 'unicode', native: SPARKLE }, replacement: '[sparkles]', effects },
    ];
    const original = `Hello <picture><source srcset="/emoji/1f44d.svg"><img alt="${thumb}" src="/emoji/1f44d.svg"></picture> there`;
    const store = createStore(reducer, fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules,
        availability: 'enabled',
        display: 'apply',
      },
      title: '',
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));

    const Block = connect(state => ({
      index: emojiMuteTextIndexFromState(state),
    }))(class HtmlBlock extends React.Component {

      componentDidMount () {
        bindEmojiMuteHtmlSources(this.node, original);
      }

      componentDidUpdate () {
        bindEmojiMuteHtmlSources(this.node, original);
      }

      setNode = node => {
        this.node = node;
      }

      render () {
        return (
          <div
            ref={this.setNode}
            dangerouslySetInnerHTML={{ __html: replaceEmojiInDisplayHtml(original, this.props.index) }}
          />
        );
      }

    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Block />
        </div>
      </Provider>,
    );

    expect(view.container.textContent).toBe(`Hello ${SPARKLE} there`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: rules,
      });
    });

    expect(view.container.textContent).toBe(`Hello ${SPARKLE} there`);
    expect(view.container.textContent).not.toContain('[sparkles]');
    view.unmount();
  });

  it('projects a custom-emoji image that is not marked emojione', () => {
    const html = '<img class="custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="10" src="https://cdn.example/blob.png">';
    const index = {
      signature: 'custom-only',
      active: true,
      replacements: new Map([['l:10', '[blob]']]),
    };

    expect(replaceEmojiInDisplayHtml(html, index)).toBe('[blob]');
    expect(replaceEmojiInDisplayHtml('<img alt="photo" src="/photos/1.jpg">', index)).toBe('<img alt="photo" src="/photos/1.jpg">');
  });

  it('projects a video description once from the original text', () => {
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rules = [
      { id: 'ok', revision: '1', emoji: { kind: 'unicode', native: OK }, replacement: SPARKLE, effects },
      { id: 'spark', revision: '1', emoji: { kind: 'unicode', native: SPARKLE }, replacement: '[sparkles]', effects },
    ];
    const store = createStore(reducer, fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules,
        availability: 'enabled',
        display: 'apply',
      },
      title: `Hi ${OK}`,
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));

    const Player = connect(state => ({
      index: emojiMuteTextIndexFromState(state),
      source: state.get('title'),
    }))(class VideoLabel extends React.Component {

      componentDidMount () {
        bindEmojiMuteElementSource(this.node, this.props.source);
      }

      componentDidUpdate () {
        bindEmojiMuteElementSource(this.node, this.props.source);
      }

      setNode = node => {
        this.node = node;
      }

      render () {
        const label = presentEmojiMutePlain(this.props.source, this.props.index);

        return (
          <video aria-label={label} title={label} ref={this.setNode} />
        );
      }

    });

    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Player />
        </div>
      </Provider>,
    );
    const video = view.container.querySelector('video');

    expect(video.getAttribute('aria-label')).toBe(`Hi ${SPARKLE}`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: rules,
      });
    });

    expect(video.getAttribute('aria-label')).toBe(`Hi ${SPARKLE}`);
    expect(video.getAttribute('title')).toBe(`Hi ${SPARKLE}`);
    expect(video.getAttribute('aria-label')).not.toContain('[sparkles]');
    view.unmount();
  });
});

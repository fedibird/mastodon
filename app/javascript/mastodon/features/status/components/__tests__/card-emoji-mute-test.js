import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutesReducer from 'mastodon/reducers/emoji_mutes';

jest.mock('mastodon/initial_state', () => ({ useBlurhash: false }));
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);

import Card from '../card';

const card = fromJS({
  url: 'https://example.test/story',
  title: 'Hello 👌',
  description: 'A long description with 👌 inside the preview text for the card.',
  provider_name: 'News 👌',
  type: 'link',
  width: 100,
  height: 400,
  image: 'https://example.test/cover.jpg',
  author_name: '',
  author_url: '',
  embed_url: '',
  html: '',
  blurhash: null,
  thumbhash: null,
});

const renderCard = display => {
  const store = createStore(state => state, fromJS({ emojiMutes: { display, rules: [] } }));

  return render(
    <Provider store={store}>
      <Card card={card} onOpenMedia={jest.fn()} />
    </Provider>,
  );
};

describe('link card unverified text', () => {
  it('hides unicode emoji in the title, description, provider, and title attribute', () => {
    const { container } = renderCard('suppress');
    const html = container.innerHTML;

    expect(html).not.toContain('👌');
    expect(container.querySelector('.status-card__title').textContent).toBe('Hello ◻');
    expect(container.querySelector('.status-card__title').getAttribute('title')).toBe('Hello ◻');
    expect(container.querySelector('.status-card__description').textContent).toContain('◻');
    expect(container.querySelector('.status-card__host').textContent).toBe('News ◻');
    expect(container.querySelector('img').getAttribute('src')).toBe('https://example.test/cover.jpg');
  });

  it('suppresses a decoded hostname and embed text without changing the embed URL', () => {
    const video = card.merge({
      provider_name: '',
      url: 'https://xn--xp8h.example/watch',
      type: 'video',
      html: '<iframe src="https://player.example/embed?v=1" title="Play 👌"></iframe><p>Watch 👌</p>',
    });
    const store = createStore(state => state, fromJS({ emojiMutes: { display: 'suppress', rules: [] } }));
    const { container } = render(
      <Provider store={store}>
        <Card card={video} onOpenMedia={jest.fn()} />
      </Provider>,
    );

    fireEvent.click(container.querySelector('button'));

    const html = container.innerHTML;
    expect(html).toContain('src="https://player.example/embed?v=1&amp;autoplay=1&amp;auto_play=1"');
    expect(html).not.toContain('👌');
    expect(container.querySelector('.status-card__host').textContent).toBe('◻.example');
    expect(container.querySelector('iframe').getAttribute('title')).toBe('Play ◻');
    expect(container.querySelector('p').textContent).toBe('Watch ◻');
  });

  it('shows the card text when emoji muting is ignored', () => {
    const { container } = renderCard('show');

    expect(container.querySelector('.status-card__title').textContent).toBe('Hello 👌');
  });

  it('projects a card title once when suppress and apply share a batch', () => {
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rules = [
      { id: 'ok', revision: '2', emoji: { kind: 'unicode', native: '👌' }, replacement: '✨', effects },
      { id: 'spark', revision: '2', emoji: { kind: 'unicode', native: '✨' }, replacement: '[sparkles]', effects },
    ];
    const titled = card.set('title', 'Hi 👌');
    const store = createStore((state, action) => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action)), fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules,
        availability: 'enabled',
        display: 'apply',
      },
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));
    const { container } = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Card card={titled} onOpenMedia={jest.fn()} />
        </div>
      </Provider>,
    );
    const title = container.querySelector('.status-card__title');

    expect(title.textContent).toBe('Hi ✨');
    expect(title.getAttribute('title')).toBe('Hi ✨');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: rules,
      });
    });

    expect(title.textContent).toBe('Hi ✨');
    expect(title.getAttribute('title')).toBe('Hi ✨');
    expect(title.textContent).not.toContain('[sparkles]');
  });

  it('projects an unprojected card title once when the rules arrive', () => {
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const titled = card.set('title', 'Hi 👌');
    const store = createStore((state, action) => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action)), fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'apply',
      },
    }));
    const guard = createUnverifiedEmojiGuard();

    store.subscribe(() => guard(store.getState()));
    const { container } = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Card card={titled} onOpenMedia={jest.fn()} />
        </div>
      </Provider>,
    );

    expect(container.querySelector('.status-card__title').textContent).toBe('Hi 👌');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [{ id: 'ok', revision: '2', emoji: { kind: 'unicode', native: '👌' }, replacement: '[ok]', effects }],
      });
    });

    const title = container.querySelector('.status-card__title');

    expect(title.textContent).toBe('Hi [ok]');
    expect(title.getAttribute('title')).toBe('Hi [ok]');
  });

  it('projects the title and description once when the rules change and keeps a React write', () => {
    const effects = { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false };
    const rule = (id, revision, native, replacement) => ({
      id, revision, emoji: { kind: 'unicode', native }, replacement, effects,
    });
    const titled = card.set('title', 'Hi 👌').set('description', 'Note 👌');
    const store = createStore((state, action) => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action)), fromJS({
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules: [rule('ok', '1', '👌', '✨'), rule('spark', '1', '✨', '[sparkles]')],
        availability: 'enabled',
        display: 'apply',
      },
    }));
    const guard = createUnverifiedEmojiGuard();
    let duringApply = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) === '3' && store.getState().getIn(['emojiMutes', 'display']) === 'apply') {
        const titleNode = document.querySelector('.status-card__title');
        const description = document.querySelector('.status-card__description');

        duringApply = {
          title: titleNode.textContent,
          titleAttr: titleNode.getAttribute('title'),
          description: description.textContent,
        };
      }
    });

    const { container } = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          <Card card={titled} onOpenMedia={jest.fn()} />
        </div>
      </Provider>,
    );
    const title = container.querySelector('.status-card__title');
    const description = container.querySelector('.status-card__description');

    expect(title.textContent).toBe('Hi ✨');
    expect(title.getAttribute('title')).toBe('Hi ✨');
    expect(description.textContent).toBe('Note ✨');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule('ok', '2', '👌', '✨'), rule('spark', '2', '✨', '[sparkles]')],
      });
    });

    expect(title.textContent).toBe('Hi ✨');
    expect(title.getAttribute('title')).toBe('Hi ✨');
    expect(description.textContent).toBe('Note ✨');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      title.firstChild.nodeValue = 'React wrote this';
      title.setAttribute('title', 'React wrote this');
      description.firstChild.nodeValue = 'React wrote the note';
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [rule('ok', '3', '👌', '[ok]'), rule('spark', '3', '✨', '[sparkles]')],
      });
    });

    expect(duringApply).toEqual({
      title: 'React wrote this',
      titleAttr: 'React wrote this',
      description: 'React wrote the note',
    });
    expect(title.textContent).toBe('Hi [ok]');
    expect(title.getAttribute('title')).toBe('Hi [ok]');
    expect(description.textContent).toBe('Note [ok]');
  });
});

import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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

  it('shows the card text when emoji muting is ignored', () => {
    const { container } = renderCard('show');

    expect(container.querySelector('.status-card__title').textContent).toBe('Hello 👌');
  });
});

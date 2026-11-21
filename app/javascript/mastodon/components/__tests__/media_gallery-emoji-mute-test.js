import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('../../initial_state', () => ({
  displayMedia: 'show_all',
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: false,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);

import MediaGallery from '../media_gallery';

const reducer = (state = fromJS({})) => state;

const attachment = (type, description) => fromJS({
  id: type,
  type,
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  remote_url: 'https://example.test/cat.jpg',
  description,
  meta: {
    small: { width: 100 },
    original: { width: 200 },
    focus: { x: 0, y: 0 },
  },
});

const renderGallery = (display, media) => {
  const store = createStore(reducer, fromJS({
    emojiMutes: { display, rules: [] },
  }));

  return render(
    <Provider store={store}>
      <MediaGallery media={fromJS(media)} height={110} visible defaultWidth={300} onOpenMedia={jest.fn()} lang='ja' />
    </Provider>,
  );
};

describe('MediaGallery unverified descriptions', () => {
  it('removes unicode emoji from alt, title, aria-label, and the badge while suppressed', () => {
    const { container } = renderGallery('suppress', [
      attachment('image', 'cat 👌 and :blob:'),
      attachment('gifv', 'dance 👌'),
    ]);
    const image = container.querySelector('img');
    const video = container.querySelector('video');

    expect(image.getAttribute('alt')).toBe('cat ◻ and :blob:');
    expect(image.getAttribute('title')).toBe('cat ◻ and :blob:');
    expect(image.getAttribute('src')).toBe('https://example.test/cat-small.jpg');
    expect(video.getAttribute('aria-label')).toBe('dance ◻');
    expect(video.getAttribute('title')).toBe('dance ◻');
    expect(container.textContent).not.toContain('👌');
    expect(container.innerHTML).not.toContain('👌');
  });

  it('shows the original description when emoji muting is off', () => {
    const { container } = renderGallery('show', [attachment('image', 'cat 👌')]);

    expect(container.querySelector('img').getAttribute('alt')).toBe('cat 👌');
  });
});

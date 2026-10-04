/* eslint-disable react/prop-types, react/jsx-no-bind */

import { render, screen, fireEvent } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/locales', () => ({
  getLocale: () => ({ localeData: [], messages: {} }),
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    addLocaleData: () => {},
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    IntlProvider: ({ children }) => <div>{children}</div>,
  };
});

jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/status/components/card', () => () => null);
jest.mock('mastodon/components/poll', () => () => null);
jest.mock('mastodon/components/hashtag', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);
jest.mock('mastodon/components/public_status_history', () => () => null);
jest.mock('mastodon/components/status_history_revision', () => () => null);

jest.mock('mastodon/components/media_gallery', () => {
  const React = require('react');

  return ({ onOpenMedia }) => (
    <button
      type='button'
      onClick={() => onOpenMedia(require('immutable').fromJS([{
        type: 'image',
        url: 'https://example.test/cat.jpg',
        preview_url: 'https://example.test/cat-small.jpg',
        description: 'a cat',
        meta: { original: { width: 200, height: 100 } },
      }]), 0)}
    >
      Open media
    </button>
  );
});

import MediaContainer from '../media_container';
import { PublicMediaModal } from 'mastodon/features/ui/components/media_modal';

const image = fromJS([{
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  description: 'a cat',
  meta: { original: { width: 200, height: 100 } },
}]);

describe('PublicMediaModal', () => {
  it('renders an image modal and closes it without a Redux provider', () => {
    const onClose = jest.fn();
    const { container } = render(
      <PublicMediaModal
        media={image}
        index={0}
        onClose={onClose}
        onChangeBackgroundColor={jest.fn()}
      />,
    );

    expect(container.querySelector('.media-modal')).not.toBeNull();

    fireEvent.click(container.querySelector('.media-modal__close'));

    expect(onClose).toHaveBeenCalled();
  });
});

describe('MediaContainer public media modal', () => {
  it('keeps the gallery portal when the real modal opens and closes', () => {
    const mediaNode = document.createElement('div');
    mediaNode.setAttribute('data-component', 'MediaGallery');
    mediaNode.setAttribute('data-props', JSON.stringify({ media: [] }));
    document.body.appendChild(mediaNode);

    render(<MediaContainer locale='en' components={[mediaNode]} />);

    fireEvent.click(screen.getByRole('button', { name: 'Open media' }));

    expect(document.querySelector('.media-modal')).not.toBeNull();
    expect(mediaNode.querySelector('button')).not.toBeNull();

    fireEvent.click(document.querySelector('.modal-root__overlay'));

    expect(document.querySelector('.media-modal')).toBeNull();
    expect(mediaNode.querySelector('button')).not.toBeNull();
  });
});

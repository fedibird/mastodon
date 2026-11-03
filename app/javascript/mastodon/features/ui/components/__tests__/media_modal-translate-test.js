/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('react-swipeable-views', () => ({ children }) => <div>{children}</div>);
jest.mock('../image_loader', () => ({ alt, lang }) => <img alt={alt} lang={lang} />);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/components/gifv', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/icon_button', () => () => null);
jest.mock('mastodon/features/picture_in_picture/components/footer', () => ({ statusId }) => (
  <div data-testid='media-status-footer' data-status-id={statusId} />
));
jest.mock('mastodon/initial_state', () => ({
  disableSwiping: true,
}));

import MediaModal from '../media_modal';

const media = fromJS([{
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  description: 'a cat',
  translation: { description: 'ねこ' },
  meta: { original: { width: 200, height: 100 } },
}]);

const renderModal = (mode) => {
  const store = createStore(() => fromJS({
    statuses: {
      s1: {
        id: 's1',
        language: 'en',
        translationMode: mode,
        translation: {
          language: 'ja',
          detected_source_language: 'en',
          provider: 'DeepL',
        },
      },
    },
  }));

  return render(
    <Provider store={store}>
      <MediaModal
        statusId='s1'
        media={media}
        index={0}
        onClose={jest.fn()}
        onChangeBackgroundColor={jest.fn()}
      />
    </Provider>,
  );
};

describe('MediaModal translation display modes', () => {
  it('uses the original description in original mode', () => {
    const { container } = renderModal('original');
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe('a cat');
    expect(image.getAttribute('lang')).toBe('en');
  });

  it('uses the translated description in translated mode', () => {
    const { container } = renderModal('translated');
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(image.getAttribute('lang')).toBe('ja');
  });

  it('uses the translated description for bilingual accessibility text', () => {
    const { container } = renderModal('bilingual');
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(image.getAttribute('lang')).toBe('ja');
  });

  it('falls back to the original description when the translated alt text is empty', () => {
    const emptyMedia = media.setIn([0, 'translation', 'description'], '');
    const store = createStore(() => fromJS({
      statuses: {
        s1: {
          id: 's1',
          language: 'en',
          translationMode: 'translated',
          translation: { language: 'ja', detected_source_language: 'en' },
        },
      },
    }));
    const { container } = render(
      <Provider store={store}>
        <MediaModal
          statusId='s1'
          media={emptyMedia}
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );

    expect(container.querySelector('img').getAttribute('alt')).toBe('a cat');
    expect(container.querySelector('img').getAttribute('lang')).toBe('en');
  });
});

describe('MediaModal cross-post navigation', () => {
  const sequence = fromJS([
    { id: 'photo-one', type: 'image', url: 'https://example.test/1.jpg', description: 'First photo' },
    { id: 'photo-two', type: 'image', url: 'https://example.test/2.jpg', description: 'Second photo' },
  ]);

  it('moves through loaded images across posts without wrapping, and changes the footer to the current status', () => {
    const store = createStore(() => fromJS({
      statuses: {
        s1: { id: 's1', language: 'en' },
        s2: { id: 's2', language: 'ja' },
      },
    }));

    render(
      <Provider store={store}>
        <MediaModal
          statusId='s1'
          timelineStatusIds={fromJS(['s1', 's2'])}
          media={sequence}
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );

    expect(screen.getByTestId('media-status-footer')).toHaveAttribute('data-status-id', 's1');
    expect(screen.queryByRole('button', { name: 'Previous' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByTestId('media-status-footer')).toHaveAttribute('data-status-id', 's2');
    expect(screen.queryByRole('button', { name: 'Next' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Previous' }));
    expect(screen.getByTestId('media-status-footer')).toHaveAttribute('data-status-id', 's1');
  });
});

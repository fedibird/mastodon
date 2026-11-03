/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
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
jest.mock('mastodon/features/video', () => ({ width, height }) => <div data-testid='modal-video' data-width={width} data-height={height} />);
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

const renderModal = (mode, items = media) => {
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
        media={items}
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

describe('MediaModal video dimensions', () => {
  it('uses original metadata rather than absent or thumbnail-sized top-level dimensions', () => {
    const video = fromJS([{
      id: 'video',
      type: 'video',
      url: 'https://example.test/clip.mp4',
      width: 120,
      height: 68,
      meta: { original: { width: 1080, height: 1920 } },
    }]);

    const { container } = renderModal('original', video);
    expect(screen.getByTestId('modal-video')).toHaveAttribute('data-width', '1080');
    expect(screen.getByTestId('modal-video')).toHaveAttribute('data-height', '1920');
    expect(container.querySelector('.media-modal__video-container').style.getPropertyValue('--modal-video-aspect')).toBe('1080 / 1920');
    expect(container.querySelector('.media-modal__video-container').style.getPropertyValue('--modal-video-width-by-height')).toBe('45vh');
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

describe('MediaModal automatic paging at the loaded image boundary', () => {
  it('shows loading while fetching older posts and advances to the next loaded image', async () => {
    const first = { id: 'first', type: 'image', url: 'https://example.test/first.jpg' };
    const second = { id: 'second', type: 'image', url: 'https://example.test/second.jpg' };
    const timelineId = 'account:alice:media:cats';
    const initial = fromJS({
      timelines: { [timelineId]: { items: ['s1'], hasMore: true, isLoading: false } },
      accounts: { alice: { id: 'alice' } },
      statuses: { s1: { id: 's1', media_attachments: [first] } },
    });

    const reducer = (state = initial, action) => {
      if (action.type === 'LOAD_OLDER') {
        return state.setIn(['timelines', timelineId, 'isLoading'], true);
      }
      if (action.type === 'LOAD_DONE') {
        return state
          .setIn(['timelines', timelineId, 'isLoading'], false)
          .setIn(['timelines', timelineId, 'hasMore'], false)
          .setIn(['timelines', timelineId, 'items'], fromJS(['s1', 's2']))
          .setIn(['statuses', 's2'], fromJS({ id: 's2', media_attachments: [second] }));
      }

      return state;
    };
    const store = createStore(reducer);
    const loadMore = jest.fn(() => store.dispatch({ type: 'LOAD_OLDER' }));

    render(
      <Provider store={store}>
        <MediaModal
          statusId='s1'
          timelineStatusIds={fromJS(['s1'])}
          media={fromJS([first])}
          mediaSource={{
            kind: 'account',
            accountId: 'alice',
            timelineId,
            afterStatusId: 's1',
            visibility: 'show_all',
            onLoadMore: loadMore,
          }}
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(loadMore).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('status')).toHaveTextContent('Loading more images');

    act(() => {
      store.dispatch({ type: 'LOAD_DONE' });
    });

    await waitFor(() => {
      expect(screen.getByTestId('media-status-footer')).toHaveAttribute('data-status-id', 's2');
    });
    expect(screen.queryByRole('status')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Next' })).toBeNull();
  });

  it('stops the loading state after a pagination failure, exposing a retry', async () => {
    const one = { id: 'one', type: 'image', url: 'https://example.test/one.jpg' };
    const timelineId = 'home:media';
    const initial = fromJS({
      timelines: { [timelineId]: { items: ['s1'], hasMore: true, isLoading: false, paginationError: false } },
      statuses: { s1: { id: 's1', media_attachments: [one] } },
    });
    const reducer = (state = initial, action) => {
      if (action.type === 'LOAD') {
        return state.setIn(['timelines', timelineId, 'isLoading'], true).setIn(['timelines', timelineId, 'paginationError'], false);
      }
      if (action.type === 'FAIL') {
        return state.setIn(['timelines', timelineId, 'isLoading'], false).setIn(['timelines', timelineId, 'paginationError'], true);
      }

      return state;
    };
    const store = createStore(reducer);
    const loadMore = jest.fn(() => store.dispatch({ type: 'LOAD' }));

    render(
      <Provider store={store}>
        <MediaModal
          statusId='s1'
          timelineStatusIds={fromJS(['s1'])}
          media={fromJS([one])}
          mediaSource={{ kind: 'timeline', timelineId, afterStatusId: 's1', visibility: 'show_all', onLoadMore: loadMore }}
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByRole('status')).toHaveTextContent('Loading more images');
    act(() => {
      store.dispatch({ type: 'FAIL' });
    });

    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent('Could not load more images');
    });
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(loadMore).toHaveBeenCalledTimes(2);
  });
});

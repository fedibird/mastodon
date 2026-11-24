import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

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

describe('open ALT popover while emoji mutes are unverified', () => {
  const thumb = '👍';
  const placeholder = '◻';

  const muteReducer = (state, action) => {
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
      });
    }

    return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
  };

  const gallery = (description, extra = {}) => (
    <MediaGallery
      media={fromJS([attachment('image', description).merge(fromJS(extra))])}
      height={110}
      visible
      defaultWidth={300}
      onOpenMedia={jest.fn()}
      lang='en'
    />
  );

  it('keeps the raw description out of the open popover and restores the latest text', () => {
    const store = createStore(muteReducer);
    const guard = createUnverifiedEmojiGuard();
    const stopGuard = store.subscribe(() => guard(store.getState()));
    let beforeCommit = null;
    const stopWatch = store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) === 'suppress' && !beforeCommit) {
        beforeCommit = document.querySelector('.media-gallery__alt__popover').outerHTML;
      }
    });
    const view = render(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          {gallery(`photo ${thumb}`)}
        </div>
      </Provider>,
    );

    fireEvent.click(view.container.querySelector('.media-gallery__alt__label'));
    const popover = () => document.querySelector('.media-gallery__alt__popover');

    expect(popover().textContent).toContain(`photo ${thumb}`);
    expect(popover().outerHTML).not.toContain('data-emoji-mute-source');
    expect(popover().getAttribute('role')).toBe('region');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(beforeCommit).not.toContain(thumb);
    expect(beforeCommit).toContain(`photo ${placeholder}`);
    expect(beforeCommit).not.toContain('data-emoji-mute-source');
    expect(popover().outerHTML).not.toContain(thumb);
    expect(popover().textContent).toContain(`photo ${placeholder}`);

    view.rerender(
      <Provider store={store}>
        <div className='emoji-mutes-privacy-portal'>
          {gallery(`photo ${placeholder}`)}
        </div>
      </Provider>,
    );

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [],
      });
    });

    expect(popover().textContent).toContain(`photo ${placeholder}`);
    expect(popover().outerHTML).not.toContain(thumb);
    expect(popover().getAttribute('class')).toContain('dropdown-animation');
    stopGuard();
    stopWatch();
    view.unmount();
  });

  it('does not put the raw description in original, translated, or bilingual popovers', () => {
    const store = createStore(muteReducer);
    const guard = createUnverifiedEmojiGuard();
    const stopGuard = store.subscribe(() => guard(store.getState()));
    const described = attachment('image', `photo ${thumb}`).set('translation', fromJS({ description: `訳 ${thumb}` }));

    ['original', 'translated', 'bilingual'].forEach(mode => {
      const view = render(
        <Provider store={store}>
          <MediaGallery
            media={fromJS([described])}
            height={110}
            visible
            defaultWidth={300}
            onOpenMedia={jest.fn()}
            lang='en'
            translationMode={mode}
            sourceLang='en'
            targetLang='ja'
          />
        </Provider>,
      );

      fireEvent.click(view.container.querySelector('.media-gallery__alt__label'));
      const popover = document.querySelector('.media-gallery__alt__popover');

      act(() => {
        store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '9' });
      });

      expect(popover.outerHTML).not.toContain(thumb);
      expect(popover.outerHTML).not.toContain('data-emoji-mute-source');
      view.unmount();
      document.querySelectorAll('.media-gallery__alt__popover').forEach(node => node.remove());
    });

    stopGuard();
  });
});

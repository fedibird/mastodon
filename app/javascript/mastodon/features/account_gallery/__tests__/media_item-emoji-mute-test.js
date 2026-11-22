import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { IntlProvider } from 'react-intl';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('mastodon/initial_state', () => ({
  autoPlayMedia: false,
  displayMedia: 'show_all',
  useBlurhash: false,
}));
jest.mock('mastodon/is_mobile', () => ({ isIOS: () => false }));
jest.mock('mastodon/components/alt_text_badge', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);

import MediaItem from '../components/media_item';

const thumb = '👍';
const placeholder = '◻';

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
    });
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

const attachment = description => fromJS({
  id: 'm1',
  type: 'image',
  description,
  preview_url: 'https://example.test/cat.jpg',
  url: 'https://example.test/cat.jpg',
  meta: { focus: { x: 0, y: 0 } },
  status: { id: '10', url: '/statuses/10', sensitive: false },
});

describe('account gallery image alt during an unverified mute sync', () => {
  it('restores the description that changed while emoji were concealed', () => {
    const store = createStore(reducer);
    const guard = createUnverifiedEmojiGuard();
    const stopGuard = store.subscribe(() => guard(store.getState()));
    const view = render(
      <Provider store={store}>
        <IntlProvider locale='en'>
          <MediaItem attachment={attachment(`Hi ${thumb}`)} onOpenMedia={jest.fn()} visibility='show_all' />
        </IntlProvider>
      </Provider>,
    );
    const image = () => view.container.querySelector('img');

    expect(image().getAttribute('alt')).toBe(`Hi ${thumb}`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(image().getAttribute('alt')).not.toContain(thumb);

    view.rerender(
      <Provider store={store}>
        <IntlProvider locale='en'>
          <MediaItem attachment={attachment(`Hi ${placeholder}`)} onOpenMedia={jest.fn()} visibility='show_all' />
        </IntlProvider>
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

    expect(image().getAttribute('alt')).toBe(`Hi ${placeholder}`);
    expect(image().getAttribute('alt')).not.toContain(thumb);
    expect(view.container.querySelector('a').getAttribute('aria-label')).toBe(`Hi ${placeholder}`);
    stopGuard();
    view.unmount();
  });
});

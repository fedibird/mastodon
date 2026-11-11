/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { POLLS_IMPORT } from 'mastodon/actions/importer';
import { screenReaderPollFromState } from 'mastodon/components/status';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import pollsReducer from 'mastodon/reducers/polls';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';

jest.mock('../components/card', () => () => null);
jest.mock('../../../components/missing_indicator', () => () => null);
jest.mock('../../../components/column_back_button', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/status_content', () => () => null);
jest.mock('mastodon/initial_state', () => ({
  boostModal: false,
  deleteModal: false,
  confirmDomainBlock: false,
  enableStatusReference: false,
  defaultColumnWidth: '400px',
  me: '1',
  maxReactionsPerAccount: 8,
  displayMedia: 'default',
}));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: () => null,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage, formatDate: () => 'Jan 1, 12:00 PM' }} />,
}));

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('../components/detailed_status', () => () => <div className='detailed-status' />);
jest.mock('../components/action_bar', () => () => null);
jest.mock('../containers/header_container', () => () => null);
jest.mock('../../ui/components/column', () => ({ children }) => <div>{children}</div>);
jest.mock('../../../components/column_header', () => () => null);
jest.mock('mastodon/containers/scroll_container', () => ({ children }) => <div>{children}</div>);
jest.mock('../../../containers/status_container', () => () => null);
jest.mock('../../ui/util/fullscreen', () => ({
  attachFullscreenListener: () => {},
  detachFullscreenListener: () => {},
  isFullscreen: () => false,
}));
jest.mock('mastodon/actions/statuses', () => ({
  fetchStatus: () => ({ type: 'NOOP' }),
  muteStatus: () => ({ type: 'NOOP' }),
  unmuteStatus: () => ({ type: 'NOOP' }),
  deleteStatus: () => ({ type: 'NOOP' }),
  expireStatus: () => ({ type: 'NOOP' }),
  requestEditStatus: () => ({ type: 'NOOP' }),
  hideStatus: () => ({ type: 'NOOP' }),
  revealStatus: () => ({ type: 'NOOP' }),
  translateStatus: () => ({ type: 'NOOP' }),
  setStatusTranslationMode: () => ({ type: 'NOOP' }),
}));

import { Status as DetailStatus } from '../index';

const intl = {
  formatMessage: ({ defaultMessage }) => defaultMessage,
  formatDate: () => 'Jan 1, 12:00 PM',
};

const makeStore = () => createStore((state = fromJS({
  emojiMutes: { revision: null, rules: [] },
  polls: {},
}), action) => state
  .set('emojiMutes', emojiMutes(state.get('emojiMutes'), action))
  .set('polls', pollsReducer(state.get('polls'), action)));

const status = fromJS({
  id: 's1',
  account: {
    id: 'a1',
    acct: 'alice',
    display_name: 'Alice',
    display_name_html: 'Alice',
  },
  content: '<p>Hello</p>',
  contentHtml: '<p>Hello</p>',
  search_index: '\n\nHello\n\nYes :blob:\n\nNo',
  spoiler_text: '',
  spoilerHtml: '',
  hidden: false,
  poll: 'p1',
  reblog: null,
  quote: null,
  media_attachments: [],
  visibility: 'public',
  created_at: '2024-01-01T00:00:00.000Z',
  sensitive: false,
});

const choice = '<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="11" src="https://cdn.example/11.svg">';

class Harness extends React.Component {

  componentDidMount() {
    this.unsubscribe = this.props.store.subscribe(() => this.forceUpdate());
  }

  componentWillUnmount() {
    this.unsubscribe();
  }

  render() {
    const shown = this.props.statusRecord;
    const poll = screenReaderPollFromState(this.props.store.getState(), shown);

    return (
      <DetailStatus
        params={{ statusId: shown.get('id') }}
        dispatch={this.props.store.dispatch}
        status={shown}
        intl={intl}
        domain='example.test'
        pictureInPicture={fromJS({ inUse: false, available: false })}
        screenReaderPoll={poll}
      />
    );

  }

}

describe('detail screen reader poll', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('speaks a renamed poll choice while the status object stays the same', () => {
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <Harness store={store} statusRecord={status} />
      </Provider>,
    );
    const label = () => container.querySelector('.detailed-status__wrapper').getAttribute('aria-label');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        mutes: [{
          id: 'm1',
          revision: '2',
          emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
          replacement: '[choice]',
          effects: { replace_in_text: true },
        }],
      });
    });

    expect(label()).toContain('Yes :blob:');

    act(() => {
      store.dispatch({
        type: POLLS_IMPORT,
        polls: [{
          id: 'p1',
          options: [
            { title: 'Sure :blob:', title_emojified: `Sure ${choice}` },
            { title: 'Later', title_emojified: 'Later' },
          ],
        }],
      });
    });

    expect(label()).toContain('Sure [choice]');
    expect(label()).toContain('Later');
    expect(label()).not.toContain('Yes');
    expect(status.get('search_index')).toContain('Yes :blob:');
  });

  it('speaks poll choices in the loaded order when only the order changed', () => {
    const stored = status.set('search_index', '\n\nHello\n\nA :blob:\n\nB');
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <Harness store={store} statusRecord={stored} />
      </Provider>,
    );
    const label = () => container.querySelector('.detailed-status__wrapper').getAttribute('aria-label');
    const image = '<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="11" src="https://cdn.example/11.svg">';

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        mutes: [{
          id: 'm1',
          revision: '2',
          emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
          replacement: '[choice]',
          effects: { replace_in_text: true },
        }],
      });
      store.dispatch({
        type: POLLS_IMPORT,
        polls: [{
          id: 'p1',
          options: [
            { title: 'B', title_emojified: 'B' },
            { title: 'A :blob:', title_emojified: `A ${image}` },
          ],
        }],
      });
    });

    const spoken = label();
    expect(spoken.indexOf('B')).toBeLessThan(spoken.indexOf('[choice]'));
    expect(spoken).toContain('A [choice]');
    expect(spoken).not.toContain(':blob:');
    expect(stored.get('search_index')).toBe('\n\nHello\n\nA :blob:\n\nB');
  });
});

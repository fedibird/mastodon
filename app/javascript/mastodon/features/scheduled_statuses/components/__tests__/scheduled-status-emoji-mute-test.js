/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';

jest.mock('react-intl', () => {
  const ReactIntl = require('react');
  const PropTypesIntl = require('prop-types');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
    formatDate: () => 'Dec 1, 00:00',
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => {
      class IntlWrapper extends ReactIntl.Component {

        static contextTypes = { router: PropTypesIntl.object };

        render() {
          return ReactIntl.createElement(Component, { ...this.props, intl });
        }

      }

      return IntlWrapper;
    },
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('mastodon/features/ui/components/bundle', () => () => <div data-testid='media' />);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/icon_button', () => ({ title, onClick }) => (
  <button type='button' aria-label={title} onClick={onClick}>delete</button>
));

import ScheduledStatus from '../scheduled_status';

const OK = '👌';

const rule = (emoji, replacement = '［絵文字］', effects = {}) => ({
  id: 'm1',
  revision: '2',
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: true,
    hide_reactions: true,
    hide_in_picker: true,
    ...effects,
  },
});

const text = `<b>Hi</b> :blob: <a href="/path/${OK}" title="${OK}">link</a> ${OK}`;

const scheduled = () => fromJS({
  id: 'sch1',
  scheduled_at: '2026-12-01T00:00:00.000Z',
  media_attachments: [],
  params: {
    text,
    language: 'ja',
    visibility: 'unlisted',
    in_reply_to_id: null,
  },
});

class RouterStub extends React.Component {

  static propTypes = { children: PropTypes.node };

  static childContextTypes = { router: PropTypes.object.isRequired };

  getChildContext() {
    return { router: { history: { push: jest.fn() } } };
  }

  render() {
    return this.props.children;
  }

}

const makeStore = () => createStore((state = fromJS({
  emojiMutes: { revision: null, rules: [] },
}), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action)));

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

describe('scheduled status preview', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces unicode in the preview and leaves the saved text, shortcode, and actions', () => {
    const record = scheduled();
    const store = makeStore();
    const onRedraft = jest.fn();
    const onDelete = jest.fn();
    const { container } = render(
      <Provider store={store}>
        <RouterStub>
          <ScheduledStatus
            scheduledStatus={record}
            onRedraftScheduledStatus={onRedraft}
            onDeleteScheduledStatus={onDelete}
          />
        </RouterStub>
      </Provider>,
    );
    const preview = () => container.querySelector('.mini-status__content__text');

    expect(preview().getAttribute('lang')).toBe('ja');
    expect(preview().querySelector('b').textContent).toBe('Hi');
    expect(preview().textContent).toContain(':blob:');
    expect(preview().textContent).toContain(OK);
    expect(container.querySelector('.mini-status__wrapper-unlisted')).not.toBeNull();
    expect(container.textContent).toContain('Dec 1, 00:00');

    apply(store, [
      rule({ kind: 'unicode', native: OK }, '<img src="https://evil.test/x.png" onerror="alert(1)">'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]);

    expect(preview().querySelector('b')).not.toBeNull();
    expect(preview().querySelector('a').getAttribute('href')).toBe(`/path/${OK}`);
    expect(preview().querySelector('a').getAttribute('title')).toBe(OK);
    expect(preview().querySelector('a').textContent).toBe('link');
    expect(preview().textContent).toContain(':blob:');
    expect(preview().textContent).toContain('<img src="https://evil.test/x.png" onerror="alert(1)">');
    expect(preview().querySelector('img')).toBeNull();
    expect(preview().querySelector('[src*="evil.test"]')).toBeNull();
    expect(preview().innerHTML).toContain('&lt;img');
    expect(preview().textContent).not.toContain(OK);
    expect(record.getIn(['params', 'text'])).toBe(text);

    fireEvent.click(preview());
    fireEvent.click(container.querySelector('[aria-label="Unselecting a post"]'));

    expect(onRedraft).toHaveBeenCalledWith(record, expect.objectContaining({ push: expect.any(Function) }), expect.anything());
    expect(onRedraft.mock.calls[0][0].getIn(['params', 'text'])).toBe(text);
    expect(onDelete).toHaveBeenCalledWith('sch1', expect.anything());

    apply(store, [
      rule({ kind: 'unicode', native: OK }, '[ok]', { replace_in_text: false }),
    ], '4');

    expect(preview().textContent).toContain(OK);
    expect(preview().querySelector('a').getAttribute('href')).toBe(`/path/${OK}`);
    expect(preview().querySelector('a').getAttribute('title')).toBe(OK);
    expect(record.getIn(['params', 'text'])).toBe(text);
  });
});

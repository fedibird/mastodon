/* eslint-disable react/prop-types -- Lightweight component doubles used by these tests. */
import React from 'react';
import { render, screen, act } from '@testing-library/react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { IntlProvider } from 'react-intl';
import { fromJS } from 'immutable';
import en from '../../../../locales/en.json';
import ja from '../../../../locales/ja.json';

// Match the existing component tests: react-intl 2's relative formatter is
// incompatible with the installed intl-relativeformat 6 in this checkout.
jest.mock('react-intl', () => {
  const React = require('react');
  const Context = React.createContext({ messages: {} });
  const format = (messages, { id, defaultMessage }, values = {}) => {
    const parts = (messages[id] || defaultMessage).split(/(\{name\})/);
    return parts.map(part => part === '{name}' ? values.name : part);
  };
  return {
    defineMessages: messages => messages,
    IntlProvider: ({ messages, children }) => <Context.Provider value={{ messages }}>{children}</Context.Provider>,
    injectIntl: Component => props => {
      const { messages } = React.useContext(Context);
      const intl = { formatMessage: (descriptor, values) => format(messages, descriptor, values).join(''), formatDate: () => 'Oct 17' };
      return <Component {...props} intl={intl} />;
    },
    FormattedMessage: props => {
      const { messages } = React.useContext(Context);
      return <React.Fragment>{React.Children.toArray(format(messages, props, props.values))}</React.Fragment>;
    },
  };
});

jest.mock('mastodon/initial_state', () => ({ me: 'me' }));
jest.mock('mastodon/features/emoji/emoji', () => ({ buildCustomEmojis: () => [], categoriesFromEmojis: () => [] }));
jest.mock('mastodon/containers/status_container', () => props => <div data-testid='status' data-id={props.id} />);
jest.mock('mastodon/containers/account_container', () => () => null);
jest.mock('../../containers/follow_request_container', () => () => null);
jest.mock('../../../../actions/boosts', () => ({ initBoostModal: jest.fn() }));
jest.mock('../../../../actions/compose', () => ({ mentionCompose: jest.fn() }));
jest.mock('../../../../actions/interactions', () => ({}));
jest.mock('../../../../actions/statuses', () => ({}));

import NotificationContainer from '../../containers/notification_container';

const booster = { id: 'booster', acct: 'booster', username: 'booster', display_name: 'Booster', display_name_html: 'Booster', url: 'https://example.test/@booster' };
const notification = fromJS({ id: '10', type: 'status', account: 'booster', status: 'wrapper', created_at: '2026-10-17T00:00:00Z' });
const data = {
  accounts: { booster, author: { id: 'author', acct: 'author' } },
  statuses: { wrapper: { id: 'wrapper', account: 'booster', reblog: 'original' }, original: { id: 'original', account: 'author' } },
};

const mount = (state = data, locale = 'en', messages = en, item = notification) => {
  const store = createStore((current = fromJS(state), action) => action.type === 'REPLACE' ? action.state : current);
  const view = render(<Provider store={store}><IntlProvider locale={locale} messages={messages}><NotificationContainer notification={item} accountId='booster' onMoveUp={jest.fn()} onMoveDown={jest.fn()} unread /></IntlProvider></Provider>);
  return { ...view, store };
};

describe('status notifications from normalized Redux entities', () => {
  it.each([
    ['en', en, 'Booster boosted a post', 'booster boosted a post'],
    ['ja', ja, 'Boosterさんがブーストしました', 'boosterさんがブーストしました'],
  ])('renders a followed boost in %s without replacing the wrapper ID', (locale, messages, text, label) => {
    mount(data, locale, messages);
    expect(document.querySelector('.notification__message span')).toHaveTextContent(text);
    expect(document.querySelector('.notification-status')).toHaveAttribute('aria-label', expect.stringContaining(label));
    expect(document.querySelector('.notification-status')).toHaveClass('unread');
    expect(document.querySelector('.fa-retweet')).not.toBeNull();
    expect(screen.getByTestId('status')).toHaveAttribute('data-id', 'wrapper');
    expect(screen.getByRole('link', { name: 'Booster' })).toHaveAttribute('href', booster.url);
  });

  it.each([
    {},
    { wrapper: { id: 'wrapper', account: 'booster' } },
    { wrapper: { id: 'wrapper', account: 'booster', reblog: 'deleted' } },
    { wrapper: { id: 'wrapper', account: 'booster', reblog: 'original' }, original: {} },
  ])('falls back safely for missing, ordinary or incomplete statuses %p', statuses => {
    mount({ ...data, statuses });
    expect(document.querySelector('.notification__message span')).toHaveTextContent('Booster just posted');
    expect(document.querySelector('.fa-home')).not.toBeNull();
    expect(screen.getByTestId('status')).toHaveAttribute('data-id', 'wrapper');
  });

  it('preserves traditional reblog notification wording and styling', () => {
    mount(data, 'en', en, notification.set('type', 'reblog'));
    expect(document.querySelector('.notification__message span')).toHaveTextContent('Booster boosted your post');
    expect(document.querySelector('.notification-reblog')).not.toBeNull();
    expect(screen.getByTestId('status')).toHaveAttribute('data-id', 'wrapper');
  });

  it('updates independent columns when a wrapper arrives or the original disappears', () => {
    const first = mount({ ...data, statuses: {} });
    const second = mount();
    expect(document.querySelectorAll('.fa-home')).toHaveLength(1);
    expect(document.querySelectorAll('.fa-retweet')).toHaveLength(1);
    act(() => {
      first.store.dispatch({ type: 'REPLACE', state: fromJS(data) });
    });
    expect(document.querySelectorAll('.fa-retweet')).toHaveLength(2);
    act(() => {
      second.store.dispatch({ type: 'REPLACE', state: fromJS({ ...data, statuses: { wrapper: data.statuses.wrapper } }) });
    });
    expect(document.querySelectorAll('.fa-home')).toHaveLength(1);
    expect(document.querySelectorAll('.fa-retweet')).toHaveLength(1);
  });

  it('uses the default English message when the locale has no translation', () => {
    mount(data, 'en', {});
    expect(document.querySelector('.notification__message span')).toHaveTextContent('Booster boosted a post');
  });
});

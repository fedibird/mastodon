import React from 'react';
import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';

jest.mock('react-intl', () => {
  const React = require('react');

  const applyPlurals = (message, values) => message.replace(
    /\{(\w+), plural, one \{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\} other \{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}\}/g,
    (_, key, one, other) => {
      const count = Number(values[key]);
      const chosen = count === 1 ? one : other;

      return chosen.replace(/\{(\w+)\}/g, (__, inner) => values[inner]);
    },
  );

  const formatMessage = ({ defaultMessage }, values = {}) => {
    const message = applyPlurals(defaultMessage || '', values);
    const parts = [];
    const pattern = /\{(\w+)\}/g;
    let lastIndex = 0;
    let match = pattern.exec(message);
    let hasElement = false;

    while (match) {
      parts.push(message.slice(lastIndex, match.index));

      const value = values[match[1]];

      if (React.isValidElement(value)) {
        hasElement = true;
      }

      parts.push(value === undefined || value === null ? '' : value);
      lastIndex = match.index + match[0].length;
      match = pattern.exec(message);
    }

    parts.push(message.slice(lastIndex));

    if (!hasElement) {
      return parts.join('');
    }

    return React.createElement(React.Fragment, null, ...parts);
  };

  const intl = {
    locale: 'en',
    formatMessage,
    formatDate: () => 'Oct 5, 12:00',
    now: () => Date.now(),
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage, values }) => formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayAvatar: false,
  autoPlayEmoji: false,
  disable_joke_appearance: false,
}));

jest.mock('mastodon/containers/status_container', () => () => null);
jest.mock('mastodon/containers/account_container', () => () => null);
jest.mock('../../containers/follow_request_container', () => () => null);

import Notification from '../notification';

const handlers = {
  onMoveUp: jest.fn(),
  onMoveDown: jest.fn(),
  onMention: jest.fn(),
  onFavourite: jest.fn(),
  onReblog: jest.fn(),
  onToggleHidden: jest.fn(),
};

const reporter = {
  id: '1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/@alice',
  avatar: 'https://example.test/alice.png',
  avatar_static: 'https://example.test/alice-static.png',
};

const target = {
  id: '2',
  acct: 'bob',
  username: 'bob',
  display_name: 'Bob',
  display_name_html: 'Bob',
  url: 'https://example.test/@bob',
  avatar: 'https://example.test/bob.png',
  avatar_static: 'https://example.test/bob-static.png',
};

const notification = (report) => fromJS({
  id: 'n1',
  type: 'admin.report',
  created_at: '2026-10-05T12:00:00.000Z',
  account: reporter,
  report,
});

const renderNotification = (payload) => render(
  <Notification notification={payload} {...handlers} />,
);

describe('admin.report notification', () => {
  const report = {
    id: '42',
    category: 'spam',
    created_at: '2026-10-05T12:00:00.000Z',
    status_ids: ['s1', 's2', 's3'],
    target_account: target,
  };

  it('links the reporter and the reported account and shows one report detail', () => {
    renderNotification(notification(report));

    const wrapper = document.querySelector('.notification-admin-report');
    const reporterLink = screen.getByRole('link', { name: 'Alice' });
    const targetLink = screen.getByRole('link', { name: 'Bob' });

    expect(wrapper).not.toBeNull();
    expect(wrapper).toHaveAttribute('aria-label', expect.stringContaining('bob'));
    expect(reporterLink).toHaveAttribute('href', 'https://example.test/@alice');
    expect(reporterLink).toHaveAttribute('to', '/accounts/1');
    expect(reporterLink).toHaveClass('notification__display-name');
    expect(targetLink).toHaveAttribute('href', 'https://example.test/@bob');
    expect(targetLink).toHaveAttribute('to', '/accounts/2');
    expect(targetLink).toHaveAttribute('title', 'bob');
    expect(targetLink).toHaveClass('notification__display-name');
    expect(document.querySelectorAll('.notification__report')).toHaveLength(1);
    expect(screen.getByRole('link', { name: 'Open report' })).toHaveAttribute('href', '/admin/reports/42');
  });

  it('does not crash when the report payload is missing', () => {
    renderNotification(notification(null));

    expect(document.querySelector('.notification-admin-report')).not.toBeNull();
    expect(document.querySelector('.notification__report')).toBeNull();
    expect(screen.getByRole('link', { name: 'Alice' })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Bob' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Open report' })).not.toBeInTheDocument();
  });
});

/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import React from 'react';
import { List as ImmutableList, fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) return defaultMessage;
      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => String(values[key]));
    },
    formatDate: () => 'Jan 02, 12:00',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => {
      if (!values) return defaultMessage;

      return defaultMessage.split(/\{(\w+)\}/).map((part, index) => (
        index % 2 === 1 ? <React.Fragment key={part}>{values[part]}</React.Fragment> : part
      ));
    },
  };
});

jest.mock('../dropdown_menu', () => ({ children, renderHeader, renderItem, items }) => (
  <div>
    {children}
    <div data-testid='history-header'>{renderHeader(items)}</div>
    <ul>
      {items.map((item, index) => renderItem(item, index, { onClick () {}, onKeyPress () {} }))}
    </ul>
  </div>
));

jest.mock('../relative_timestamp', () => () => <time>relative</time>);
jest.mock('../icon', () => () => null);

import EditedTimestamp from '../edited_timestamp';

const renderTimestamp = (timestamp, historyItems = ImmutableList()) => {
  const store = createStore(() => fromJS({
    dropdown_menu: { openId: null, keyboard: false },
    history: {
      s1: { loading: false, items: historyItems },
    },
    accounts: {
      a1: {
        id: 'a1',
        username: 'alice',
        avatar: 'https://example.com/alice.png',
        avatar_static: 'https://example.com/alice.png',
      },
    },
  }));

  return render(
    <Provider store={store}>
      <EditedTimestamp statusId='s1' timestamp={timestamp} />
    </Provider>,
  );
};

describe('EditedTimestamp', () => {
  it('shows the edited history control when edited_at is present', () => {
    renderTimestamp('2026-01-02T00:00:00.000Z', fromJS([
      { created_at: '2026-01-02T00:00:00.000Z', original: false, account: 'a1' },
      { created_at: '2026-01-01T00:00:00.000Z', original: true, account: 'a1' },
    ]));

    expect(screen.getByRole('button', { name: /Edited/ })).toBeInTheDocument();
    expect(screen.getByTestId('history-header')).toHaveTextContent('Edited');
    expect(screen.getAllByText('alice').length).toBeGreaterThan(0);
  });

  it('renders a history item when the editor account is missing', () => {
    renderTimestamp('2026-01-02T00:00:00.000Z', fromJS([
      { created_at: '2026-01-01T00:00:00.000Z', original: true, account: null },
    ]));

    expect(screen.getByRole('button', { name: /Edited/ })).toBeInTheDocument();
    expect(screen.getByText(/created/)).toBeInTheDocument();
  });

  it('renders nothing when edited_at is absent', () => {
    const { container } = renderTimestamp(null);
    expect(container).toBeEmptyDOMElement();
    expect(screen.queryByRole('button', { name: /Edited/ })).not.toBeInTheDocument();
  });
});
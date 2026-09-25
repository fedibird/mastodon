/* eslint-disable react/prop-types, react/jsx-no-bind */

import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) return defaultMessage;
      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => String(values[key] ?? ''));
    },
    formatDate: () => 'Sep 25, 05:58',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage, values }) => {
      if (!values) return defaultMessage;
      if (defaultMessage.includes('plural')) {
        return values.count === 1 ? 'Edited 1 time' : `Edited ${values.count} times`;
      }

      return defaultMessage.split(/\{(\w+)\}/).map((part, index) => (
        index % 2 === 1 ? <React.Fragment key={`${part}-${index}`}>{values[part]}</React.Fragment> : part
      ));
    },
  };
});

jest.mock('mastodon/components/dropdown_menu', () => ({ children, renderHeader, renderItem, items, onOpen, onItemClick }) => (
  <div>
    <button type='button' data-testid='open-history' onClick={() => onOpen('menu', null, false)}>
      {children}
    </button>
    <div data-testid='history-header'>{renderHeader(items)}</div>
    <ul>
      {items.map((item, index) => (
        <li key={index}>
          {renderItem(item, index, { onClick: () => onItemClick(item, index), onKeyPress () {} })}
        </li>
      ))}
    </ul>
  </div>
));

jest.mock('mastodon/components/relative_timestamp', () => () => <time>relative</time>);
jest.mock('mastodon/components/avatar', () => () => <span data-testid='avatar' />);
jest.mock('mastodon/components/icon', () => () => <span data-testid='caret' />);

import PublicStatusHistory from '../public_status_history';
import StatusHistoryRevision from '../status_history_revision';

const revisions = [
  {
    content: '<p>original</p>',
    created_at: '2026-01-01T00:00:00.000Z',
    account: {
      id: 'a1',
      username: 'alice',
      acct: 'alice',
      display_name: 'Alice',
      note: '',
      followed_message: '',
      url: 'https://example.test/@alice',
      emojis: [],
      avatar: 'https://example.test/a.png',
      avatar_static: 'https://example.test/a.png',
    },
  },
  {
    content: '<p>edited</p>',
    created_at: '2026-01-02T00:00:00.000Z',
    account: null,
  },
];

const renderHistory = (onOpenRevision = jest.fn()) => render(
  <PublicStatusHistory
    statusId='s1'
    editedAt='2026-09-25T05:58:00.000Z'
    historyUrl='/@alice/s1/history'
    onOpenRevision={onOpenRevision}
  />,
);

describe('PublicStatusHistory', () => {
  beforeEach(() => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(revisions),
    }));
  });

  it('shows the edited date and loads history once, newest first', async () => {
    const onOpenRevision = jest.fn();
    renderHistory(onOpenRevision);

    expect(screen.getByTestId('open-history')).toHaveTextContent('Edited Sep 25, 05:58');
    expect(global.fetch).not.toHaveBeenCalled();

    fireEvent.click(screen.getByTestId('open-history'));

    await waitFor(() => expect(screen.getByText('alice')).toBeInTheDocument());
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith('/@alice/s1/history', expect.objectContaining({
      credentials: 'same-origin',
    }));
    expect(screen.getByTestId('history-header')).toHaveTextContent('Edited 1 time');

    const labels = screen.getAllByRole('button').map(button => button.textContent);
    const editedIndex = labels.findIndex(label => label.includes('edited'));
    const createdIndex = labels.findIndex(label => label.includes('created'));
    expect(editedIndex).toBeGreaterThan(-1);
    expect(createdIndex).toBeGreaterThan(editedIndex);

    fireEvent.click(screen.getAllByRole('button').find(button => button.textContent.includes('edited')));
    expect(onOpenRevision).toHaveBeenCalledWith(expect.anything(), undefined);
    expect(onOpenRevision.mock.calls[0][0].get('content')).toBe('<p>edited</p>');

    fireEvent.click(screen.getByTestId('open-history'));
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  it('normalizes the editor display name before opening the revision', async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve([
        {
          content: '<p>original</p>',
          created_at: '2026-01-01T00:00:00.000Z',
          account: {
            id: 'a1',
            username: 'alice',
            acct: 'alice',
            display_name: 'Alice :emoji:',
            note: '',
            followed_message: '',
            url: 'https://example.test/@alice',
            emojis: [],
            avatar: 'https://example.test/a.png',
            avatar_static: 'https://example.test/a.png',
          },
        },
      ]),
    }));

    const onOpenRevision = jest.fn();
    renderHistory(onOpenRevision);
    fireEvent.click(screen.getByTestId('open-history'));

    await waitFor(() => expect(screen.getByText(/created/)).toBeInTheDocument());
    fireEvent.click(screen.getByText(/created/));

    const account = onOpenRevision.mock.calls[0][0].get('account');
    expect(account.get('display_name_html')).toContain('Alice');

    render(
      <StatusHistoryRevision
        revision={onOpenRevision.mock.calls[0][0]}
        account={account}
        onClose={() => {}}
      />,
    );

    expect(screen.getByText('Alice :emoji:')).toBeInTheDocument();
    expect(screen.getByText('@alice')).toBeInTheDocument();
  });

  it('renders a revision whose editor account is missing', async () => {
    renderHistory();
    fireEvent.click(screen.getByTestId('open-history'));

    await waitFor(() => expect(screen.getByText(/edited/)).toBeInTheDocument());
    expect(screen.getByText(/edited/).textContent).not.toContain('alice');
  });
});

import React from 'react';
import { render, screen } from '@testing-library/react';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';

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

import Report from '../report';

const reporter = ImmutableMap({
  id: '1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  avatar: 'https://example.test/alice.png',
  avatar_static: 'https://example.test/alice-static.png',
});

const target = ImmutableMap({
  id: '2',
  acct: 'bob',
  username: 'bob',
  display_name: 'Bob',
  url: 'https://example.test/@bob',
  avatar: 'https://example.test/bob.png',
  avatar_static: 'https://example.test/bob-static.png',
});

const buildReport = (overrides = {}) => ImmutableMap({
  id: '42',
  category: 'spam',
  created_at: '2026-10-05T12:00:00.000Z',
  status_ids: ImmutableList(['s1', 's2', 's3']),
  target_account: target,
  ...overrides,
});

const renderReport = (props = {}) => render(
  <Report account={reporter} report={buildReport()} {...props} />,
);

describe('Report notification detail', () => {
  it('renders the target account as the base avatar and the reporter as the overlay', () => {
    const { container } = renderReport();
    const base = container.querySelector('.account__avatar-overlay-base');
    const overlay = container.querySelector('.account__avatar-overlay-overlay');

    expect(base.style.backgroundImage).toContain('bob-static.png');
    expect(overlay.style.backgroundImage).toContain('alice-static.png');
  });

  it('shows the report created_at timestamp', () => {
    const { container } = renderReport();

    expect(container.querySelector('time')).toHaveAttribute('datetime', '2026-10-05T12:00:00.000Z');
  });

  it('shows how many statuses are attached', () => {
    const { container } = renderReport();

    expect(container).toHaveTextContent('3 posts attached');
  });

  it.each([
    ['spam', 'Spam'],
    ['legal', 'Legal'],
    ['violation', 'Rule violation'],
    ['other', 'Other'],
  ])('shows the %s category', (category, label) => {
    renderReport({ report: buildReport({ category }) });

    expect(screen.getByText(label)).toBeInTheDocument();
  });

  it('falls back to other for an unknown or missing category', () => {
    const { rerender } = renderReport({ report: buildReport({ category: 'unknown' }) });

    expect(screen.getByText('Other')).toBeInTheDocument();

    rerender(
      <Report account={reporter} report={buildReport({ category: null })} />,
    );

    expect(screen.getByText('Other')).toBeInTheDocument();
  });

  it('opens the admin report in a new tab', () => {
    renderReport();

    const link = screen.getByRole('link', { name: 'Open report' });

    expect(link).toHaveAttribute('href', '/admin/reports/42');
    expect(link).toHaveAttribute('target', '_blank');
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'));
    expect(link).toHaveAttribute('rel', expect.stringContaining('noreferrer'));
  });

  it('does not expose report details when hidden', () => {
    const { container } = renderReport({ hidden: true });

    expect(container).toHaveTextContent('42');
    expect(container.querySelector('.notification__report')).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Open report' })).not.toBeInTheDocument();
    expect(screen.queryByText('Spam')).not.toBeInTheDocument();
    expect(screen.queryByText(/attached/)).not.toBeInTheDocument();
  });

  it('does not crash when status_ids or the target account are missing', () => {
    const { container } = renderReport({
      report: buildReport({
        status_ids: null,
        target_account: null,
      }),
    });

    expect(container).toHaveTextContent('0 posts attached');
    expect(container.querySelector('.account__avatar-overlay')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Open report' })).toBeInTheDocument();
  });

  it('renders nothing when the report is missing', () => {
    const { container } = renderReport({ report: null });

    expect(container).toBeEmptyDOMElement();
  });
});

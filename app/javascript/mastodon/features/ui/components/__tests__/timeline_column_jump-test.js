import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: (message, values) => {
      let text = message.defaultMessage || message.id;

      if (values) {
        Object.keys(values).forEach(key => {
          text = text.replace(`{${key}}`, values[key]);
        });
      }

      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import TimelineColumnJumpPanel from '../timeline_column_jump';

const home = {
  source: 'home',
  path: '/api/v1/timelines/home',
  params: { visibilities: [] },
};

const personal = {
  source: 'personal',
  path: '/api/v1/timelines/personal',
  params: {},
};

const renderPanel = (props) => render(
  <TimelineColumnJumpPanel
    contract={home}
    panelId='jump-1'
    onSubmit={jest.fn(() => Promise.resolve({ outcome: 'not_in_source', reason: 'not_in_source', moved: false }))}
    onSearchAccounts={jest.fn(() => Promise.resolve({ ok: true, accounts: [] }))}
    onInvalidate={jest.fn()}
    onClose={jest.fn()}
    {...props}
  />,
);

describe('TimelineColumnJumpPanel', () => {
  it('jumps by a local date-time and does not send text', () => {
    const onSubmit = jest.fn(() => Promise.resolve({ outcome: 'resolved', moved: true, precision: 'nearest-before' }));
    renderPanel({ onSubmit });

    fireEvent.change(screen.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));

    expect(onSubmit).toHaveBeenCalledTimes(1);
    const query = onSubmit.mock.calls[0][0];

    expect(query.kind).toBe('date');
    expect(query.preference).toBe('nearest');
    expect(query.target.at).toMatch(/^2026-10-17T09:30:00[+-]\d{2}:\d{2}$/);
    expect(query.target.q).toBeUndefined();
    expect(JSON.stringify(query)).not.toContain('secret');
  });

  it('keeps text search closed on a mix and Shift+Enter does not submit a date jump', () => {
    const onSubmit = jest.fn();
    renderPanel({
      onSubmit,
      contract: { source: 'mix', path: '/mix', params: {} },
    });

    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'text' } });

    expect(screen.getByText('This timeline cannot be searched by text.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Jump' })).toBeDisabled();
    expect(screen.queryByLabelText('Text')).toBeNull();

    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'date' } });
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter', shiftKey: true });

    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByText('Moving between text results is not available.')).toBeTruthy();
  });

  it('closes on Escape and forgets the draft when opened again', () => {
    const onClose = jest.fn();
    const view = renderPanel({ onClose });

    fireEvent.change(screen.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });

    expect(onClose).toHaveBeenCalledTimes(1);

    view.unmount();
    renderPanel({});

    expect(screen.getByLabelText('Date and time').value).toBe('');
  });

  it('submits an account id without the lookup text and ignores a stale result', async () => {
    let resolveSearch;
    let resolveJump;
    const onSearchAccounts = jest.fn(() => new Promise(resolve => {
      resolveSearch = resolve;
    }));
    const onSubmit = jest.fn(() => new Promise(resolve => {
      resolveJump = resolve;
    }));
    renderPanel({ onSearchAccounts, onSubmit });

    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'account' } });
    fireEvent.change(screen.getByLabelText('Account'), { target: { value: '@alice' } });

    await new Promise(resolve => {
      setTimeout(resolve, 300);
    });
    resolveSearch({
      ok: true,
      accounts: [{ id: '42', acct: 'alice', display_name: 'Alice' }],
    });

    expect(await screen.findByRole('button', { name: 'Alice @alice' })).toBeTruthy();
    expect(onSearchAccounts).toHaveBeenCalledWith('alice');

    fireEvent.click(screen.getByRole('button', { name: 'Alice @alice' }));
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));

    expect(onSubmit.mock.calls[0][0].target).toEqual({ accountId: '42' });
    expect(onSubmit.mock.calls[0][0].target.q).toBeUndefined();

    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'date' } });
    resolveJump({ outcome: 'resolved', moved: true });

    await Promise.resolve();
    expect(screen.queryByText('Moved in history.')).toBeNull();
  });

  it('does not offer an account jump on a personal timeline', () => {
    renderPanel({ contract: personal });

    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'account' } });

    expect(screen.getByText('This timeline cannot be jumped by account.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Jump' })).toBeDisabled();
    expect(screen.queryByLabelText('Account')).toBeNull();
  });

  it('sends a large post id as a string', () => {
    const onSubmit = jest.fn(() => Promise.resolve({ outcome: 'not_found', reason: 'not_found', moved: false }));
    const id = '9223372036854775807';

    renderPanel({ onSubmit });
    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'status' } });
    fireEvent.change(screen.getByLabelText('Post ID'), { target: { value: id } });
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));

    expect(onSubmit.mock.calls[0][0].target.id).toBe(id);
  });
});

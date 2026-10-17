import { act, fireEvent, render, screen } from '@testing-library/react';
import fs from 'fs';
import path from 'path';
import React from 'react';

jest.mock('react-intl', () => {
  const ReactIntl = require('react');
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
    formatDate: (date) => date.toISOString(),
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <ReactIntl.Fragment><Component {...props} intl={intl} /></ReactIntl.Fragment>,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import TimelineColumnJumpPanel from '../timeline_column_jump';

const home = {
  source: 'home',
  path: '/api/v1/timelines/home',
  params: { visibilities: [] },
};

const post = (id, text) => ({
  id,
  created_at: '2026-10-17T01:02:03.000Z',
  content: `<p>${text}</p>`,
  account: { id: '7', display_name: 'Ada', acct: 'ada' },
});

const membership = (rows, outcome) => ({
  ok: true,
  body: {
    outcome: outcome || (rows.some(row => row.outcome === 'unknown') ? 'partial' : 'complete'),
    results: rows,
    limitations: rows.some(row => row.outcome === 'unknown') ? ['retention_2000'] : [],
    limits: {
      ids: 50,
      session_candidates: 200,
      search_page_default: 20,
      search_page: 40,
      max_search_pages: 10,
    },
  },
});

const renderText = (props) => {
  const onSearchStatuses = props.onSearchStatuses || jest.fn(() => Promise.resolve({ ok: true, statuses: [], received: 0 }));
  const onCheckMembership = props.onCheckMembership || jest.fn(() => Promise.resolve(membership([])));
  const view = render(
    <TimelineColumnJumpPanel
      contract={home}
      panelId='jump-1'
      columnId='column-a'
      accountId='1'
      locationKey='route-a'
      splitSessionId=''
      onSubmit={jest.fn()}
      onSearchAccounts={jest.fn()}
      onInvalidate={jest.fn()}
      onClose={jest.fn()}
      onJumpStatus={jest.fn(() => Promise.resolve({ moved: false }))}
      onSearchStatuses={onSearchStatuses}
      onCheckMembership={onCheckMembership}
      onCancelTextSearch={props.onCancelTextSearch || jest.fn()}
      {...props}
    />,
  );

  fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'text' } });

  return view;
};

const defer = () => {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });

  return { promise, resolve };
};

describe('timeline text search panel', () => {
  it('keeps a non-member out of the DOM until membership, then lists only members', async () => {
    const search = defer();
    const check = defer();
    const onSearchStatuses = jest.fn(() => search.promise);
    const onCheckMembership = jest.fn(() => check.promise);

    renderText({ onSearchStatuses, onCheckMembership });
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'needle' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    });

    expect(screen.queryByText('private-candidate-phrase')).toBeNull();
    expect(screen.queryByText('member-candidate-phrase')).toBeNull();
    expect(onCheckMembership).not.toHaveBeenCalled();

    await act(async () => {
      search.resolve({
        ok: true,
        received: 2,
        statuses: [
          post('10', 'private-candidate-phrase'),
          post('20', 'member-candidate-phrase'),
        ],
      });
      await Promise.resolve();
    });

    expect(screen.queryByText('private-candidate-phrase')).toBeNull();
    expect(screen.queryByText('member-candidate-phrase')).toBeNull();
    expect(onCheckMembership).toHaveBeenCalledTimes(1);
    expect(onCheckMembership.mock.calls[0][0].ids).toEqual(['10', '20']);
    expect(JSON.stringify(onCheckMembership.mock.calls[0][0])).not.toContain('needle');

    await act(async () => {
      check.resolve(membership([
        { id: '10', outcome: 'not_visible' },
        { id: '20', outcome: 'member' },
      ]));
      await Promise.resolve();
    });

    expect(screen.queryByText('private-candidate-phrase')).toBeNull();
    expect(screen.getByText('member-candidate-phrase')).toBeTruthy();
    expect(screen.getByText('Ada @ada')).toBeTruthy();
    expect(document.body.innerHTML).not.toContain('private-candidate-phrase');
    expect(screen.getByText(/Some hits are outside the retained range|Checked 2 search hits/)).toBeTruthy();
  });

  it('does not search on an IME enter and does search on a committed enter', async () => {
    const onSearchStatuses = jest.fn(() => Promise.resolve({ ok: true, statuses: [], received: 0 }));

    renderText({ onSearchStatuses });
    const input = screen.getByLabelText('Text');

    fireEvent.change(input, { target: { value: '変換中' } });
    fireEvent.compositionStart(input);
    fireEvent.keyDown(input, { key: 'Enter', keyCode: 229 });
    fireEvent.submit(input.closest('form'));

    expect(onSearchStatuses).not.toHaveBeenCalled();

    fireEvent.compositionEnd(input);
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter', shiftKey: true });

    expect(onSearchStatuses).not.toHaveBeenCalled();

    await act(async () => {
      fireEvent.submit(input.closest('form'));
      await Promise.resolve();
    });

    expect(onSearchStatuses).toHaveBeenCalledWith(expect.objectContaining({
      q: '変換中',
      offset: 0,
      limit: 20,
    }));
  });

  it('ignores a stale response after the column changes and forgets the query on close', async () => {
    const search = defer();
    const onSearchStatuses = jest.fn(() => search.promise);
    const onClose = jest.fn();
    const view = renderText({ onSearchStatuses, onClose, columnId: 'column-a' });

    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'secret-query' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    });

    view.rerender(
      <TimelineColumnJumpPanel
        contract={home}
        panelId='jump-1'
        columnId='column-b'
        accountId='1'
        locationKey='route-a'
        splitSessionId=''
        onSubmit={jest.fn()}
        onSearchAccounts={jest.fn()}
        onInvalidate={jest.fn()}
        onClose={onClose}
        onJumpStatus={jest.fn()}
        onSearchStatuses={onSearchStatuses}
        onCheckMembership={jest.fn()}
        onCancelTextSearch={jest.fn()}
      />,
    );

    await act(async () => {
      search.resolve({
        ok: true,
        received: 1,
        statuses: [post('9', 'stale-column-phrase')],
      });
      await Promise.resolve();
    });

    expect(screen.queryByText('stale-column-phrase')).toBeNull();
    expect(screen.getByLabelText('Text').value).toBe('');

    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'secret-query' } });
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });

    expect(onClose).toHaveBeenCalled();
    view.unmount();
    renderText({});

    expect(screen.getByLabelText('Text').value).toBe('');
  });

  it('does not skip a result when the jump fails, and stacks the narrow layout', async () => {
    const onJumpStatus = jest.fn()
      .mockResolvedValueOnce({ moved: true, outcome: 'resolved' })
      .mockResolvedValueOnce({ moved: false, reason: 'filtered', outcome: 'unavailable' })
      .mockResolvedValueOnce({ moved: false, reason: 'filtered', outcome: 'unavailable' });
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 2,
      statuses: [
        post('30', 'newer-hit'),
        post('10', 'older-hit'),
      ],
    }));
    const onCheckMembership = jest.fn(() => Promise.resolve(membership([
      { id: '30', outcome: 'member' },
      { id: '10', outcome: 'member' },
    ])));

    renderText({ onSearchStatuses, onCheckMembership, onJumpStatus });
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'hits' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Search' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByText('newer-hit')).toBeTruthy();
    expect(screen.getByText('older-hit')).toBeTruthy();

    const stack = document.querySelector('.timeline-jump__stack');

    expect(stack.getAttribute('data-layout')).toBe('stack');
    expect(stack.querySelector('.timeline-jump__results')).not.toBeNull();
    expect(stack.querySelector('.timeline-jump__nav')).not.toBeNull();
    expect(stack.querySelectorAll('.timeline-jump__results > li > button')).toHaveLength(2);

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /older-hit/ }));
      await Promise.resolve();
    });

    expect(onJumpStatus).toHaveBeenCalledTimes(1);
    expect(onJumpStatus.mock.calls[0][0]).toEqual({ statusId: '10' });
    expect(JSON.stringify(onJumpStatus.mock.calls[0][0])).not.toContain('hits');
    expect(screen.getByRole('button', { name: /older-hit/ }).getAttribute('aria-current')).toBe('true');

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter', shiftKey: true });

    await act(async () => {
      await Promise.resolve();
    });

    expect(onJumpStatus).toHaveBeenCalledTimes(2);
    expect(onJumpStatus.mock.calls[1][0]).toEqual({ statusId: '30' });
    expect(screen.getByRole('button', { name: /older-hit/ }).getAttribute('aria-current')).toBe('true');

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter', shiftKey: true });

    await act(async () => {
      await Promise.resolve();
    });

    expect(onJumpStatus.mock.calls[2][0]).toEqual({ statusId: '30' });
    expect(screen.getByRole('button', { name: /older-hit/ }).getAttribute('aria-current')).toBe('true');
  });

  it('offers another page only while the cap is open and hides an unknown hit', async () => {
    const calls = [];
    const onSearchStatuses = jest.fn(({ offset }) => {
      calls.push(offset);
      const statuses = [post(offset === 0 ? '40' : '15', offset === 0 ? 'page-one' : 'page-two')];

      if (offset === 0) {
        statuses.push(post('39', 'unknown-hit'));

        for (let index = 0; index < 18; index += 1) {
          statuses.push(post(String(1000 + index), `filler-${index}`));
        }
      }

      return Promise.resolve({ ok: true, statuses, received: statuses.length });
    });
    const onCheckMembership = jest.fn((payload) => Promise.resolve(membership(payload.ids.map(id => ({
      id,
      outcome: id === '39' ? 'unknown' : 'member',
      reason: id === '39' ? 'outside_retained_range' : undefined,
    })))));

    renderText({ onSearchStatuses, onCheckMembership });
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'paged' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Search' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.queryByText('unknown-hit')).toBeNull();
    expect(screen.getByText(/Some hits are outside the retained range/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Check the next page' })).toBeEnabled();

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Check the next page' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(calls).toEqual([0, 20]);
    expect(screen.getByText('page-two')).toBeTruthy();
    expect(screen.queryByText('unknown-hit')).toBeNull();
  });

  it('defines the text-search messages in English and Japanese', () => {
    const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/en.json'), 'utf8'));
    const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/ja.json'), 'utf8'));
    const ids = [
      'timeline.jump_text_hint',
      'timeline.jump_text_redis',
      'timeline.jump_text_partial',
      'timeline.jump_text_uncertain',
      'timeline.jump_text_previous',
      'timeline.jump_text_next',
      'timeline.jump_text_more',
    ];

    ids.forEach(id => {
      expect(en[id]).toEqual(expect.any(String));
      expect(ja[id]).toEqual(expect.any(String));
      expect(en[id]).not.toBe(ja[id]);
    });

    expect(en['timeline.jump_text_hint']).toContain('request URL');
    expect(ja['timeline.jump_text_hint']).toContain('URL');
    expect(ja['timeline.jump_text_uncertain']).toContain('タイムライン全体に無い');
  });
});

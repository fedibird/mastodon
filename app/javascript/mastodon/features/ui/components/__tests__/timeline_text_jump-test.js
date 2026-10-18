/* eslint-disable react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <ReactIntl.Fragment><Component {...props} intl={intl} /></ReactIntl.Fragment>,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import TimelineSplitControllerCore from '../timeline_split_controller_core';

const splitId = 'home:split:column-a:sess';
const intl = { formatMessage: message => message.defaultMessage || message.id };
const items = ImmutableList(['100', '90', '80']);
const windowState = ImmutableMap({ anchorId: '90', revision: 1, generation: 1 });

const post = (id, text) => ({
  id,
  created_at: '2026-10-17T01:02:03.000Z',
  content: `<p>${text}</p>`,
  account: { id: '7', display_name: 'Ada', acct: 'ada' },
});

const renderCore = (props) => render(
  <TimelineSplitControllerCore
    intl={intl}
    sourceTimelineId='home'
    columnId='column-a'
    multiColumn
    location={props.location || { key: 'A' }}
    splitRatio={35}
    onSplitRatioCommit={() => {}}
    unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
    activeSplitId={splitId}
    onCreate={() => {}}
    onDestroy={() => {}}
    onSaveReturnAnchor={() => {}}
    onClearReturnAnchor={() => {}}
    historyContract={{ source: 'home', path: '/api/v1/timelines/home', params: {} }}
    historyItemIds={items}
    historyBoundaryId={props.historyBoundaryId === undefined ? '100' : props.historyBoundaryId}
    historySeek={props.historySeek || null}
    onSeekTimeline={props.onSeekTimeline || jest.fn(() => Promise.resolve({ result: { outcome: 'not_in_source', reason: 'not_in_source' }, snapshot: { items, windowState } }))}
    onRestoreJump={props.onRestoreJump || jest.fn()}
    onSettleJumpScroll={jest.fn()}
    onCaptureHistoryPosition={props.onCaptureHistoryPosition || jest.fn()}
    onSearchStatuses={props.onSearchStatuses}
    onCheckMembership={props.onCheckMembership}
    onCancelTextSearch={jest.fn()}
    onResolveLoadedRow={props.onResolveLoadedRow || jest.fn(() => null)}
    onPointJump={props.onPointJump || jest.fn(() => ({ sessionId: null, snapshot: { items, windowState } }))}
    accountId='1'
  >
    {split => (
      <div>
        {split.jumpButton}
        {split.jumpPanel}
      </div>
    )}
  </TimelineSplitControllerCore>,
);

const core = (props, historySeek) => (
  <TimelineSplitControllerCore
    intl={intl}
    sourceTimelineId='home'
    columnId='column-a'
    multiColumn
    location={props.location || { key: 'A' }}
    splitRatio={35}
    onSplitRatioCommit={() => {}}
    unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
    activeSplitId={splitId}
    onCreate={() => {}}
    onDestroy={() => {}}
    onSaveReturnAnchor={() => {}}
    onClearReturnAnchor={() => {}}
    historyContract={{ source: 'home', path: '/api/v1/timelines/home', params: {} }}
    historyItemIds={items}
    historyBoundaryId={props.historyBoundaryId === undefined ? '100' : props.historyBoundaryId}
    historySeek={historySeek || props.historySeek || null}
    onSeekTimeline={props.onSeekTimeline}
    onRestoreJump={props.onRestoreJump}
    onSettleJumpScroll={jest.fn()}
    onCaptureHistoryPosition={props.onCaptureHistoryPosition || jest.fn()}
    onSearchStatuses={props.onSearchStatuses}
    onCheckMembership={props.onCheckMembership}
    onCancelTextSearch={jest.fn()}
    onResolveLoadedRow={props.onResolveLoadedRow}
    onPointJump={props.onPointJump}
    accountId='1'
  >
    {split => (
      <div>
        {split.jumpButton}
        {split.jumpPanel}
      </div>
    )}
  </TimelineSplitControllerCore>
);

const searchMember = async (text) => {
  fireEvent.click(screen.getByRole('button', { name: 'Find in this timeline' }));
  fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'text' } });
  fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'needle' } });

  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    await Promise.resolve();
    await Promise.resolve();
  });

  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: new RegExp(text) }));
    await Promise.resolve();
  });
};

describe('timeline text result jumps', () => {
  it('seeks a missing row as searchHit and does not send the query or touch saved position', async () => {
    const onSeekTimeline = jest.fn(() => Promise.resolve({
      result: { outcome: 'not_in_source', reason: 'not_in_source' },
      snapshot: { items, windowState },
    }));
    const onCaptureHistoryPosition = jest.fn();
    const onPointJump = jest.fn();
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('50', 'missing-hit')],
    }));
    const onCheckMembership = jest.fn(() => Promise.resolve({
      ok: true,
      body: {
        outcome: 'complete',
        results: [{ id: '50', outcome: 'member' }],
        limitations: [],
        limits: { ids: 50, session_candidates: 200, search_page_default: 20, search_page: 40, max_search_pages: 10 },
      },
    }));

    renderCore({
      onSeekTimeline,
      onCaptureHistoryPosition,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: () => null,
    });

    await searchMember('missing-hit');

    expect(onCaptureHistoryPosition).not.toHaveBeenCalled();
    expect(onPointJump).not.toHaveBeenCalled();
    expect(onSeekTimeline).toHaveBeenCalledTimes(1);
    const query = onSeekTimeline.mock.calls[0][0].query;

    expect(query.kind).toBe('searchHit');
    expect(query.target).toEqual({ id: '50' });
    expect(JSON.stringify(onSeekTimeline.mock.calls[0][0])).not.toContain('needle');
  });

  it('scrolls a loaded row in place and restores when the row is filtered', async () => {
    const onSeekTimeline = jest.fn();
    const onRestoreJump = jest.fn();
    const onPointJump = jest.fn(() => ({
      sessionId: 'point-1',
      snapshot: { items, windowState },
    }));
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('90', 'loaded-hit')],
    }));
    const onCheckMembership = jest.fn(() => Promise.resolve({
      ok: true,
      body: {
        outcome: 'complete',
        results: [{ id: '90', outcome: 'member' }],
        limitations: [],
        limits: { ids: 50, session_candidates: 200, search_page_default: 20, search_page: 40, max_search_pages: 10 },
      },
    }));
    const view = renderCore({
      onSeekTimeline,
      onRestoreJump,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: (statusId) => (statusId === '90' ? '90' : null),
      historySeek: ImmutableMap({ id: 'point-1', scrollStatus: 'pending', anchorId: '90' }),
    });

    await searchMember('loaded-hit');

    expect(onSeekTimeline).not.toHaveBeenCalled();
    expect(onPointJump).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      anchorId: '90',
      statusId: '90',
    }));
    expect(JSON.stringify(onPointJump.mock.calls[0][0])).not.toContain('needle');

    await act(async () => {
      view.rerender(core({
        onSeekTimeline,
        onRestoreJump,
        onPointJump,
        onSearchStatuses,
        onCheckMembership,
        onResolveLoadedRow: () => '90',
      }, ImmutableMap({
        id: 'point-1',
        scrollStatus: 'filtered',
        scrollReason: 'filtered',
        anchorId: '90',
      })));
      await Promise.resolve();
    });

    expect(onRestoreJump).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'point-1',
      items,
      windowState,
      reason: 'filtered',
    }));
    expect(screen.getByRole('button', { name: /loaded-hit/ }).getAttribute('aria-current')).toBeNull();
  });

  it('does not scroll a loaded row when membership changed before the jump', async () => {
    const onSeekTimeline = jest.fn();
    const onPointJump = jest.fn();
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('90', 'loaded-hit')],
    }));
    const onCheckMembership = jest.fn()
      .mockResolvedValueOnce({
        ok: true,
        body: {
          outcome: 'complete',
          results: [{ id: '90', outcome: 'member' }],
          limitations: [],
          limits: { ids: 50 },
        },
      })
      .mockResolvedValueOnce({
        ok: true,
        body: {
          outcome: 'complete',
          results: [{ id: '90', outcome: 'not_visible', reason: 'viewer_filter' }],
          limitations: [],
          limits: { ids: 50 },
        },
      });

    renderCore({
      onSeekTimeline,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: () => '90',
    });

    await searchMember('loaded-hit');

    expect(onCheckMembership).toHaveBeenCalledTimes(2);
    expect(onCheckMembership.mock.calls[1][0].ids).toEqual(['90']);
    expect(JSON.stringify(onCheckMembership.mock.calls[1][0])).not.toContain('needle');
    expect(onPointJump).not.toHaveBeenCalled();
    expect(onSeekTimeline).not.toHaveBeenCalled();
    expect(screen.getByText('A filter or permission is hiding that post.')).toBeTruthy();
    expect(screen.getByRole('button', { name: /loaded-hit/ }).getAttribute('aria-current')).toBeNull();
  });

  it('scrolls the boost wrapper after the recheck confirms the original id', async () => {
    const onSeekTimeline = jest.fn();
    const onPointJump = jest.fn(() => ({ sessionId: 'point-boost', snapshot: { items, windowState } }));
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('150', 'boost-hit')],
    }));
    const onCheckMembership = jest.fn(() => Promise.resolve({
      ok: true,
      body: {
        outcome: 'complete',
        results: [{ id: '150', outcome: 'member' }],
        limitations: [],
        limits: { ids: 50 },
      },
    }));

    renderCore({
      onSeekTimeline,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: (statusId) => (statusId === '150' ? '200' : null),
      historyBoundaryId: '300',
      historySeek: ImmutableMap({ id: 'point-boost', scrollStatus: 'pending', anchorId: '200' }),
    });

    await searchMember('boost-hit');

    expect(onSeekTimeline).not.toHaveBeenCalled();
    expect(onPointJump).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      anchorId: '200',
      statusId: '150',
    }));
    expect(JSON.stringify(onPointJump.mock.calls[0][0])).not.toContain('boost');
  });

  it('does not point a loaded row that is newer than the split boundary', async () => {
    const onSeekTimeline = jest.fn();
    const onPointJump = jest.fn();
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('80', 'live-side-hit')],
    }));
    const onCheckMembership = jest.fn(() => Promise.resolve({
      ok: true,
      body: {
        outcome: 'complete',
        results: [{ id: '80', outcome: 'member' }],
        limitations: [],
        limits: { ids: 50 },
      },
    }));

    renderCore({
      onSeekTimeline,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: () => '500',
      historyBoundaryId: '400',
    });

    await searchMember('live-side-hit');

    expect(onPointJump).not.toHaveBeenCalled();
    expect(onSeekTimeline).not.toHaveBeenCalled();
    expect(screen.getByText('That post is on the live side of the split. History was not moved.')).toBeTruthy();
    expect(screen.getByRole('button', { name: /live-side-hit/ }).getAttribute('aria-current')).toBeNull();
  });

  it('drops a membership recheck that returns after the route changes', async () => {
    let resolveRecheck;
    const onSeekTimeline = jest.fn();
    const onPointJump = jest.fn();
    const onSearchStatuses = jest.fn(() => Promise.resolve({
      ok: true,
      received: 1,
      statuses: [post('90', 'loaded-hit')],
    }));
    const onCheckMembership = jest.fn()
      .mockImplementationOnce(() => Promise.resolve({
        ok: true,
        body: {
          outcome: 'complete',
          results: [{ id: '90', outcome: 'member' }],
          limitations: [],
          limits: { ids: 50 },
        },
      }))
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRecheck = resolve;
      }));
    const view = renderCore({
      onSeekTimeline,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: () => '90',
    });

    fireEvent.click(screen.getByRole('button', { name: 'Find in this timeline' }));
    fireEvent.change(screen.getByLabelText('What to find'), { target: { value: 'text' } });
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'needle' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Search' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /loaded-hit/ }));
      await Promise.resolve();
    });

    view.rerender(core({
      onSeekTimeline,
      onPointJump,
      onSearchStatuses,
      onCheckMembership,
      onResolveLoadedRow: () => '90',
      location: { key: 'B' },
    }));

    await act(async () => {
      resolveRecheck({
        ok: true,
        body: {
          outcome: 'complete',
          results: [{ id: '90', outcome: 'member' }],
          limitations: [],
          limits: { ids: 50 },
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(onPointJump).not.toHaveBeenCalled();
    expect(onSeekTimeline).not.toHaveBeenCalled();
  });
});

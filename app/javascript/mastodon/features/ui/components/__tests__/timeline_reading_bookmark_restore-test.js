/* eslint-disable react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
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

import { bindHistorySurface, emitHistorySurfaceScroll, resetHistorySurfaces } from 'mastodon/timeline_position/surface';
import TimelineSplitControllerCore from '../timeline_split_controller_core';

const splitId = 'home:split:column-a:sess';
const intl = { formatMessage: message => message.defaultMessage || message.id };
const items = ['100', '90', '80'];
const windowState = { anchorId: '90', revision: 1, generation: 1 };
const anchor = {
  version: 1,
  statusId: '80',
  displayRowId: 'f-80',
  offsetPx: 12,
  alignment: 'center',
};
const saved = {
  id: '4',
  name: 'Morning',
  source: 'home',
  sourceTimelineId: 'home',
  context: {},
  anchor,
  sourceLabel: null,
  availability: { source: 'available', anchor: 'visible', membership: 'unchecked', limitations: ['retention_2000'] },
  lockVersion: 2,
  updatedAt: '2026-10-18T01:00:00Z',
};

const member = {
  ok: true,
  body: { outcome: 'complete', results: [{ id: '80', outcome: 'member' }] },
};

const seekResult = () => Promise.resolve({
  result: {
    outcome: 'resolved',
    anchorId: '80',
    scroll: { pending: true, sessionId: 'seek-1', revision: 2 },
  },
  snapshot: { items, windowState },
});

const renderBookmarks = (props = {}) => {
  const onSeekTimeline = props.onSeekTimeline || jest.fn(seekResult);
  const onCheckMembership = props.onCheckMembership || jest.fn(() => Promise.resolve(member));
  const onRestoreJump = props.onRestoreJump || jest.fn();
  const onResumeHistory = props.onResumeHistory || jest.fn();
  const onCaptureHistoryPosition = props.onCaptureHistoryPosition || jest.fn();
  const onCreate = props.onCreateReadingBookmark || jest.fn(() => Promise.resolve(saved));
  const historySeek = props.historySeek === undefined ? ImmutableMap({
    id: 'seek-1',
    scrollStatus: 'pending',
    scrollRevision: 2,
    anchorId: '80',
  }) : props.historySeek;

  const view = render(
    <TimelineSplitControllerCore
      intl={intl}
      sourceTimelineId='home'
      columnId='column-a'
      multiColumn
      location={props.location || { key: 'A' }}
      splitRatio={35}
      onSplitRatioCommit={() => {}}
      unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
      activeSplitId={props.activeSplitId === undefined ? splitId : props.activeSplitId}
      onCreate={() => {}}
      onDestroy={() => {}}
      onSaveReturnAnchor={() => {}}
      onClearReturnAnchor={() => {}}
      historyContract={props.historyContract || { source: 'home', path: '/api/v1/timelines/home', params: {} }}
      historySeek={historySeek}
      historyResume={props.historyResume}
      onSeekTimeline={onSeekTimeline}
      onCheckMembership={onCheckMembership}
      onRestoreJump={onRestoreJump}
      onReadHistoryWindow={props.onReadHistoryWindow}
      onSettleJumpScroll={props.onSettleJumpScroll || jest.fn()}
      onResumeHistory={onResumeHistory}
      onCaptureHistoryPosition={onCaptureHistoryPosition}
      onListReadingBookmarks={props.onListReadingBookmarks || jest.fn(() => Promise.resolve([saved]))}
      onCreateReadingBookmark={onCreate}
      onRenameReadingBookmark={jest.fn()}
      onDeleteReadingBookmark={jest.fn()}
    >
      {split => (
        <div>
          {split.bookmarkButton}
          {split.bookmarkPanel}
        </div>
      )}
    </TimelineSplitControllerCore>,
  );

  return { view, onSeekTimeline, onCheckMembership, onRestoreJump, onResumeHistory, onCaptureHistoryPosition, onCreate };
};

const openPanel = async () => {
  fireEvent.click(screen.getByRole('button', { name: 'Reading bookmarks' }));
  await screen.findByRole('button', { name: 'Return' });
};

describe('timeline reading bookmark restore', () => {
  beforeEach(() => {
    bindHistorySurface(splitId, { capture: () => anchor });
  });

  afterEach(() => {
    resetHistorySurfaces();
  });

  it('saves the history anchor and does not resume or capture the P3 registry', async () => {
    const liveOnly = { version: 1, statusId: '999', displayRowId: '999', offsetPx: 0, alignment: 'top' };

    bindHistorySurface('home', { capture: () => liveOnly });
    const { onCreate, onResumeHistory, onCaptureHistoryPosition, onSeekTimeline } = renderBookmarks();

    await openPanel();
    fireEvent.change(screen.getByLabelText('Bookmark name'), { target: { value: 'Morning' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save this position' }));
    await screen.findByText('Saved “Morning”.');

    expect(onCreate).toHaveBeenCalledWith({ name: 'Morning', anchor });
    expect(onCreate.mock.calls[0][0].anchor.statusId).toBe('80');
    expect(onResumeHistory).not.toHaveBeenCalled();
    expect(onCaptureHistoryPosition).not.toHaveBeenCalled();
    expect(onSeekTimeline).not.toHaveBeenCalled();
  });

  it('seeks this column history and commits only after the row settles', async () => {
    const { view, onSeekTimeline, onCheckMembership, onRestoreJump, onResumeHistory } = renderBookmarks();

    await openPanel();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    });

    expect(onCheckMembership).toHaveBeenCalledWith(expect.objectContaining({
      source: 'home',
      ids: ['80'],
    }));
    expect(JSON.stringify(onCheckMembership.mock.calls[0][0])).not.toContain('Morning');
    expect(onSeekTimeline).toHaveBeenCalledWith(expect.objectContaining({
      sourceTimelineId: 'home',
      splitTimelineId: splitId,
    }));
    expect(onSeekTimeline.mock.calls[0][0].query.target).toEqual({ id: '80' });
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).not.toBe('home');
    expect(onRestoreJump).not.toHaveBeenCalled();
    expect(onResumeHistory).not.toHaveBeenCalled();

    view.rerender(
      <TimelineSplitControllerCore
        intl={intl}
        sourceTimelineId='home'
        columnId='column-a'
        multiColumn
        location={{ key: 'A' }}
        splitRatio={35}
        onSplitRatioCommit={() => {}}
        unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
        activeSplitId={splitId}
        onCreate={() => {}}
        onDestroy={() => {}}
        onSaveReturnAnchor={() => {}}
        onClearReturnAnchor={() => {}}
        historyContract={{ source: 'home', path: '/api/v1/timelines/home', params: {} }}
        historySeek={ImmutableMap({ id: 'seek-1', scrollStatus: 'loaded', scrollRevision: 2, anchorId: '80', scrollReason: 'loaded' })}
        onSeekTimeline={onSeekTimeline}
        onCheckMembership={onCheckMembership}
        onRestoreJump={onRestoreJump}
        onSettleJumpScroll={jest.fn()}
        onResumeHistory={onResumeHistory}
        onCaptureHistoryPosition={jest.fn()}
        onListReadingBookmarks={jest.fn(() => Promise.resolve([saved]))}
        onCreateReadingBookmark={jest.fn()}
        onRenameReadingBookmark={jest.fn()}
        onDeleteReadingBookmark={jest.fn()}
      >
        {split => (
          <div>
            {split.bookmarkButton}
            {split.bookmarkPanel}
          </div>
        )}
      </TimelineSplitControllerCore>,
    );

    expect(await screen.findByText('Returned to the saved post.')).toBeTruthy();
    expect(onRestoreJump).not.toHaveBeenCalled();
  });

  it('puts the history window back when the row is filtered and leaves it when the reader scrolls', async () => {
    const onRestoreJump = jest.fn();
    const onSettleJumpScroll = jest.fn();
    const { view, onSeekTimeline, onCheckMembership } = renderBookmarks({ onRestoreJump, onSettleJumpScroll });

    await openPanel();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    });
    emitHistorySurfaceScroll(splitId);
    await act(async () => {
      await Promise.resolve();
    });

    expect(onSettleJumpScroll).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-1',
      scrolled: false,
      reason: 'user_scroll',
    }));
    expect(onRestoreJump).not.toHaveBeenCalled();

    view.unmount();
    resetHistorySurfaces();
    bindHistorySurface(splitId, { capture: () => anchor });
    const filtered = renderBookmarks({ onRestoreJump, onSeekTimeline, onCheckMembership });

    await openPanel();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    });
    filtered.view.rerender(
      <TimelineSplitControllerCore
        intl={intl}
        sourceTimelineId='home'
        columnId='column-a'
        multiColumn
        location={{ key: 'A' }}
        splitRatio={35}
        onSplitRatioCommit={() => {}}
        unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
        activeSplitId={splitId}
        onCreate={() => {}}
        onDestroy={() => {}}
        onSaveReturnAnchor={() => {}}
        onClearReturnAnchor={() => {}}
        historyContract={{ source: 'home', path: '/api/v1/timelines/home', params: {} }}
        historySeek={ImmutableMap({ id: 'seek-1', scrollStatus: 'filtered', scrollRevision: 2, anchorId: '80', scrollReason: 'filtered' })}
        onSeekTimeline={onSeekTimeline}
        onCheckMembership={onCheckMembership}
        onRestoreJump={onRestoreJump}
        onSettleJumpScroll={jest.fn()}
        onResumeHistory={jest.fn()}
        onCaptureHistoryPosition={jest.fn()}
        onListReadingBookmarks={jest.fn(() => Promise.resolve([saved]))}
        onCreateReadingBookmark={jest.fn()}
        onRenameReadingBookmark={jest.fn()}
        onDeleteReadingBookmark={jest.fn()}
      >
        {split => (
          <div>
            {split.bookmarkButton}
            {split.bookmarkPanel}
          </div>
        )}
      </TimelineSplitControllerCore>,
    );

    expect(await screen.findByText('Could not return to that post. History was put back.')).toBeTruthy();
    expect(onRestoreJump).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-1',
      reason: 'filtered',
      items,
      windowState,
    }));
  });

  it('drops a return when the route changes or automatic resume is already running', async () => {
    let release;
    const gate = new Promise(resolve => {
      release = resolve;
    });
    const onCheckMembership = jest.fn(() => gate.then(() => member));
    const onSeekTimeline = jest.fn(seekResult);
    const { view } = renderBookmarks({ onCheckMembership, onSeekTimeline });

    await openPanel();
    fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    view.rerender(
      <TimelineSplitControllerCore
        intl={intl}
        sourceTimelineId='home'
        columnId='column-a'
        multiColumn
        location={{ key: 'B' }}
        splitRatio={35}
        onSplitRatioCommit={() => {}}
        unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
        activeSplitId={splitId}
        onCreate={() => {}}
        onDestroy={() => {}}
        onSaveReturnAnchor={() => {}}
        onClearReturnAnchor={() => {}}
        historyContract={{ source: 'home', path: '/api/v1/timelines/home', params: {} }}
        historySeek={ImmutableMap({ id: 'seek-1', scrollStatus: 'pending', scrollRevision: 2, anchorId: '80' })}
        onSeekTimeline={onSeekTimeline}
        onCheckMembership={onCheckMembership}
        onRestoreJump={jest.fn()}
        onSettleJumpScroll={jest.fn()}
        onResumeHistory={jest.fn()}
        onCaptureHistoryPosition={jest.fn()}
        onListReadingBookmarks={jest.fn(() => Promise.resolve([saved]))}
        onCreateReadingBookmark={jest.fn()}
        onRenameReadingBookmark={jest.fn()}
        onDeleteReadingBookmark={jest.fn()}
      >
        {split => (
          <div>
            {split.bookmarkButton}
            {split.bookmarkPanel}
          </div>
        )}
      </TimelineSplitControllerCore>,
    );
    release();
    await act(async () => {
      await gate;
      await Promise.resolve();
    });

    expect(onSeekTimeline).not.toHaveBeenCalled();

    view.unmount();
    renderBookmarks({
      historyResume: ImmutableMap({ phase: 'seek_pending', requestId: 'history-resume-1' }),
      onSeekTimeline,
      onCheckMembership: jest.fn(),
    });
    await openPanel();
    fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    expect(await screen.findByText('Automatic resume is in progress. The bookmark was not applied.')).toBeTruthy();
    expect(onSeekTimeline).not.toHaveBeenCalled();
  });

  it('reports a redis miss as uncertain and does not seek', async () => {
    const onSeekTimeline = jest.fn(seekResult);
    const onCheckMembership = jest.fn(() => Promise.resolve({
      ok: true,
      body: { outcome: 'partial', results: [{ id: '80', outcome: 'unknown', reason: 'outside_retained_range' }] },
    }));

    renderBookmarks({ onSeekTimeline, onCheckMembership });
    await openPanel();
    fireEvent.click(screen.getByRole('button', { name: 'Return' }));

    expect(await screen.findByText('That post is outside the retained range, or its place in this timeline is unknown. History was not moved.')).toBeTruthy();
    expect(onSeekTimeline).not.toHaveBeenCalled();
  });

  it('puts the pre-seek window back when seek rejects', async () => {
    const prior = { items, windowState, seekId: null, scrollStatus: null };
    const moved = {
      items: ['80'],
      windowState: { anchorId: '80', revision: 2, generation: 2 },
      seekId: 'seek-fail',
      scrollStatus: null,
    };
    let seeking = false;
    const onSeekTimeline = jest.fn(() => {
      seeking = true;
      return Promise.reject(new Error('seek failed'));
    });
    const onRestoreJump = jest.fn();
    const onReadHistoryWindow = jest.fn(() => (seeking ? moved : prior));

    renderBookmarks({ onSeekTimeline, onRestoreJump, onReadHistoryWindow });
    await openPanel();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    });

    expect(onRestoreJump).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-fail',
      items,
      windowState,
      reason: 'not_loaded',
    }));
    expect(await screen.findByText('Could not return to that post. History was put back.')).toBeTruthy();
  });
});

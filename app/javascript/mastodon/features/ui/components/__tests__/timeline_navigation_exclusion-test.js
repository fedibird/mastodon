/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen, within } from '@testing-library/react';
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

import { captureHistoryPosition } from 'mastodon/actions/timeline_position';
import { historySourceIdentity, historyViewIdentity } from 'mastodon/timeline_position/identity';
import { resetPositionRegistry } from 'mastodon/timeline_position/session';
import { emitHistorySurfaceScroll, resetHistorySurfaces } from 'mastodon/timeline_position/surface';
import { homeHistoryContract } from 'mastodon/windowed_history/sources';
import TimelineSplitControllerCore from '../timeline_split_controller_core';

const splitId = 'home:split:column-a:sess';
const otherSplitId = 'home:split:column-b:sess';
const contract = homeHistoryContract(['public']);
const intl = { formatMessage: message => message.defaultMessage || message.id };
const items = ['100', '90', '80'];
const windowState = { anchorId: '90', revision: 1, generation: 1 };
const anchor = {
  version: 1,
  statusId: '80',
  displayRowId: '80',
  offsetPx: 12,
  alignment: 'top',
};
const savedBookmark = {
  id: '4',
  name: 'Morning',
  source: 'home',
  sourceTimelineId: 'home',
  context: { visibilities: ['public'] },
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
const pendingSeek = ImmutableMap({
  id: 'seek-1',
  scrollStatus: 'pending',
  scrollRevision: 2,
  anchorId: '50',
});

const seekPayload = () => ({
  result: {
    outcome: 'resolved',
    anchorId: '80',
    scroll: { pending: true, sessionId: 'seek-1', revision: 2, scrolled: false, reason: 'pending' },
  },
  snapshot: { items, windowState },
});

const remember = () => captureHistoryPosition({
  accountId: '1',
  source: historySourceIdentity('home', contract),
  view: historyViewIdentity({
    columnId: 'column-a',
    sourceTimelineId: 'home',
    locationKey: 'A',
  }),
  anchor,
  routeEntryKey: 'A',
  sync: true,
});

const Core = ({
  columnId = 'column-a',
  activeSplitId = splitId,
  location = { key: 'A' },
  historyResume = null,
  historySeek = pendingSeek,
  onSeekTimeline,
  onRestoreJump,
  onResumeHistory,
  onCancelHistoryResume,
  onCheckMembership,
  onCreate,
  showBookmarks = false,
}) => (
  <TimelineSplitControllerCore
    intl={intl}
    sourceTimelineId='home'
    columnId={columnId}
    accountId='1'
    multiColumn
    location={location}
    splitRatio={35}
    composerText='composer-draft-secret'
    onSplitRatioCommit={() => {}}
    unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
    activeSplitId={activeSplitId}
    onCreate={onCreate || (() => {})}
    onDestroy={() => {}}
    onSaveReturnAnchor={() => {}}
    onClearReturnAnchor={() => {}}
    historyContract={contract}
    historySeek={historySeek}
    historyResume={historyResume}
    onSeekTimeline={onSeekTimeline}
    onCheckMembership={onCheckMembership}
    onRestoreJump={onRestoreJump}
    onSettleJumpScroll={jest.fn()}
    onResumeHistory={onResumeHistory}
    onCancelHistoryResume={onCancelHistoryResume}
    onCaptureHistoryPosition={jest.fn()}
    onListReadingBookmarks={showBookmarks ? jest.fn(() => Promise.resolve([savedBookmark])) : undefined}
    onCreateReadingBookmark={showBookmarks ? jest.fn(() => Promise.resolve(savedBookmark)) : undefined}
    onRenameReadingBookmark={showBookmarks ? jest.fn() : undefined}
    onDeleteReadingBookmark={showBookmarks ? jest.fn() : undefined}
  >
    {split => (
      <div>
        {split.resumeButton}
        {split.jumpButton}
        {split.jumpPanel}
        {split.bookmarkButton}
        {split.bookmarkPanel}
      </div>
    )}
  </TimelineSplitControllerCore>
);

const submitDateJump = async (root = screen) => {
  fireEvent.click(root.getByRole('button', { name: 'Find in this timeline' }));
  fireEvent.change(root.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });

  await act(async () => {
    fireEvent.click(root.getByRole('button', { name: 'Jump' }));
    await Promise.resolve();
  });
};

describe('timeline navigation exclusion', () => {
  beforeEach(() => {
    resetPositionRegistry();
    resetHistorySurfaces();
  });

  afterEach(() => {
    resetHistorySurfaces();
  });

  it('cancels an in-flight resume before a date jump seeks this history column', async () => {
    const onSeekTimeline = jest.fn(() => Promise.resolve(seekPayload()));
    const onCancelHistoryResume = jest.fn();
    const onResumeHistory = jest.fn();
    const onRestoreJump = jest.fn();

    render(
      <Core
        historyResume={ImmutableMap({ phase: 'seek_pending', requestId: 'history-resume-9' })}
        onSeekTimeline={onSeekTimeline}
        onCancelHistoryResume={onCancelHistoryResume}
        onResumeHistory={onResumeHistory}
        onRestoreJump={onRestoreJump}
      />,
    );

    await submitDateJump();

    expect(onCancelHistoryResume).toHaveBeenCalledWith({
      splitTimelineId: splitId,
      requestId: 'history-resume-9',
      reason: 'seek',
    });
    expect(onSeekTimeline).toHaveBeenCalledTimes(1);
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).toBe(splitId);
    expect(onSeekTimeline.mock.calls[0][0].sourceTimelineId).toBe('home');
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).not.toBe('home');
    expect(JSON.stringify(onSeekTimeline.mock.calls[0][0])).not.toContain('composer-draft-secret');
    expect(onResumeHistory).not.toHaveBeenCalled();
    expect(onRestoreJump).not.toHaveBeenCalled();
  });

  it('restores an unconfirmed jump once when resume starts, and ignores a later settle', async () => {
    remember();
    const onSeekTimeline = jest.fn(() => Promise.resolve(seekPayload()));
    const onRestoreJump = jest.fn();
    const onResumeHistory = jest.fn();
    const view = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
      />,
    );

    await submitDateJump();
    fireEvent.click(screen.getByRole('button', { name: 'Resume saved place' }));

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onRestoreJump.mock.calls[0][0]).toEqual(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-1',
      reason: 'not_loaded',
    }));
    expect(onResumeHistory).toHaveBeenCalledWith(expect.objectContaining({
      explicit: true,
      splitTimelineId: splitId,
      sourceTimelineId: 'home',
    }));

    view.rerender(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
        historySeek={pendingSeek.set('scrollStatus', 'filtered').set('scrollReason', 'filtered')}
      />,
    );

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onResumeHistory).toHaveBeenCalledTimes(1);
  });

  it('does not rewind a jump when the reader scrolls before seek resolves', async () => {
    let resolveSeek;
    const onSeekTimeline = jest.fn(() => new Promise(resolve => {
      resolveSeek = resolve;
    }));
    const onRestoreJump = jest.fn();
    const view = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Find in this timeline' }));
    fireEvent.change(screen.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));
    emitHistorySurfaceScroll(splitId);

    await act(async () => {
      resolveSeek(seekPayload());
      await Promise.resolve();
      await Promise.resolve();
    });

    view.rerender(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
        historySeek={pendingSeek.set('scrollStatus', 'filtered').set('scrollReason', 'filtered')}
      />,
    );

    expect(onSeekTimeline).toHaveBeenCalledTimes(1);
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).toBe(splitId);
    expect(onRestoreJump).not.toHaveBeenCalled();
  });

  it('lets a jump replace a queued resume and a bookmark return while that resume is queued', async () => {
    remember();
    const onCreate = jest.fn();
    const onSeekTimeline = jest.fn(() => Promise.resolve(seekPayload()));
    const onResumeHistory = jest.fn();
    const onCheckMembership = jest.fn(() => Promise.resolve(member));
    const view = render(
      <Core
        activeSplitId={null}
        onCreate={onCreate}
        onSeekTimeline={onSeekTimeline}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
        onCheckMembership={onCheckMembership}
        showBookmarks
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Resume saved place' }));
    expect(onCreate).toHaveBeenCalledTimes(1);
    expect(onResumeHistory).not.toHaveBeenCalled();

    await submitDateJump();

    view.rerender(
      <Core
        activeSplitId={onCreate.mock.calls[0][0]}
        onCreate={onCreate}
        onSeekTimeline={onSeekTimeline}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
        onCheckMembership={onCheckMembership}
        showBookmarks
      />,
    );

    expect(onResumeHistory).not.toHaveBeenCalled();
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).not.toBe('home');
    expect(JSON.stringify(onSeekTimeline.mock.calls)).not.toContain('composer-draft-secret');

    view.unmount();
    resetPositionRegistry();
    remember();
    const queued = render(
      <Core
        activeSplitId={null}
        onCreate={onCreate}
        onSeekTimeline={jest.fn(() => Promise.resolve(seekPayload()))}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
        onCheckMembership={onCheckMembership}
        showBookmarks
      />,
    );

    onResumeHistory.mockClear();
    onCreate.mockClear();
    fireEvent.click(screen.getByRole('button', { name: 'Resume saved place' }));
    fireEvent.click(screen.getByRole('button', { name: 'Reading bookmarks' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Return' }));

    expect(await screen.findByText('Automatic resume is in progress. The bookmark was not applied.')).toBeTruthy();
    expect(onCheckMembership).not.toHaveBeenCalled();

    queued.rerender(
      <Core
        activeSplitId={onCreate.mock.calls[0][0]}
        onCreate={onCreate}
        onSeekTimeline={jest.fn()}
        onResumeHistory={onResumeHistory}
        onCancelHistoryResume={jest.fn()}
        onCheckMembership={onCheckMembership}
        showBookmarks
      />,
    );

    expect(onResumeHistory).toHaveBeenCalledWith(expect.objectContaining({
      explicit: true,
      sourceTimelineId: 'home',
    }));
  });

  it('drops a bookmark membership once a jump starts, and a jump once a bookmark return starts', async () => {
    let releaseMembership;
    const onCheckMembership = jest.fn(() => new Promise(resolve => {
      releaseMembership = resolve;
    }));
    const onSeekTimeline = jest.fn(() => Promise.resolve(seekPayload()));
    const onRestoreJump = jest.fn();
    const view = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onCheckMembership={onCheckMembership}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
        showBookmarks
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Reading bookmarks' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Return' }));
    await submitDateJump();

    await act(async () => {
      releaseMembership(member);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(onSeekTimeline).toHaveBeenCalledTimes(1);
    expect(onSeekTimeline.mock.calls[0][0].query.kind).toBe('date');
    expect(onSeekTimeline.mock.calls[0][0].query.target.id).toBeUndefined();
    expect(onSeekTimeline.mock.calls[0][0].splitTimelineId).toBe(splitId);
    expect(onRestoreJump).not.toHaveBeenCalled();

    view.unmount();
    onRestoreJump.mockClear();
    const again = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onCheckMembership={jest.fn(() => Promise.resolve(member))}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
        showBookmarks
      />,
    );

    onSeekTimeline.mockClear();
    await submitDateJump();
    fireEvent.click(screen.getByRole('button', { name: 'Reading bookmarks' }));

    await act(async () => {
      fireEvent.click(await screen.findByRole('button', { name: 'Return' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onRestoreJump.mock.calls[0][0].splitTimelineId).toBe(splitId);
    expect(onSeekTimeline).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      query: expect.objectContaining({ target: { id: '80' } }),
    }));
    expect(JSON.stringify(onSeekTimeline.mock.calls)).not.toContain('composer-draft-secret');
    again.unmount();
  });

  it('seeks only the column that was jumped and drops the jump when that column id changes', async () => {
    const onSeekA = jest.fn(() => Promise.resolve(seekPayload()));
    const onSeekB = jest.fn(() => Promise.resolve(seekPayload()));
    const first = render(
      <Core columnId='column-a' activeSplitId={splitId} onSeekTimeline={onSeekA} onResumeHistory={jest.fn()} onCancelHistoryResume={jest.fn()} />,
    );
    const second = render(
      <Core columnId='column-b' activeSplitId={otherSplitId} onSeekTimeline={onSeekB} onResumeHistory={jest.fn()} onCancelHistoryResume={jest.fn()} />,
    );

    await submitDateJump(within(first.container));

    expect(onSeekA).toHaveBeenCalledTimes(1);
    expect(onSeekA.mock.calls[0][0].splitTimelineId).toBe(splitId);
    expect(onSeekB).not.toHaveBeenCalled();
    expect(JSON.stringify(onSeekA.mock.calls[0][0])).not.toContain('composer-draft-secret');

    first.unmount();
    second.unmount();

    const onRestoreJump = jest.fn();
    const onSeekTimeline = jest.fn(() => Promise.resolve(seekPayload()));
    const moved = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
      />,
    );

    await submitDateJump();
    moved.rerender(
      <Core
        columnId='column-b'
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
      />,
    );

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onRestoreJump.mock.calls[0][0].splitTimelineId).toBe(splitId);

    moved.rerender(
      <Core
        columnId='column-b'
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
        historySeek={pendingSeek.set('scrollStatus', 'filtered').set('scrollReason', 'filtered')}
      />,
    );

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
  });

  it('does not restore a jump that resolves after the column unmounts', async () => {
    let resolveSeek;
    const onSeekTimeline = jest.fn(() => new Promise(resolve => {
      resolveSeek = resolve;
    }));
    const onRestoreJump = jest.fn();
    const view = render(
      <Core
        onSeekTimeline={onSeekTimeline}
        onRestoreJump={onRestoreJump}
        onResumeHistory={jest.fn()}
        onCancelHistoryResume={jest.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Find in this timeline' }));
    fireEvent.change(screen.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));
    view.unmount();

    await act(async () => {
      resolveSeek(seekPayload());
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(onSeekTimeline).toHaveBeenCalledTimes(1);
    expect(onRestoreJump).not.toHaveBeenCalled();
  });
});

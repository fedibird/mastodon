/* eslint-disable react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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

import { emitHistorySurfaceScroll, resetHistorySurfaces } from 'mastodon/timeline_position/surface';
import TimelineSplitControllerCore from '../timeline_split_controller_core';

const splitId = 'home:split:column-a:sess';
const intl = { formatMessage: message => message.defaultMessage || message.id };
const items = ImmutableList(['100', '90', '80']);
const windowState = ImmutableMap({ anchorId: '90', revision: 1, generation: 1 });
const pendingSeek = ImmutableMap({
  id: 'seek-1',
  scrollStatus: 'pending',
  scrollRevision: 2,
  anchorId: '50',
});

const seekResult = () => Promise.resolve({
  result: {
    outcome: 'resolved',
    scroll: {
      pending: true,
      sessionId: 'seek-1',
      revision: 2,
      scrolled: false,
      reason: 'pending',
    },
  },
  snapshot: { items, windowState },
});

const renderJump = ({ historySeek = pendingSeek, onRestoreJump, onSettleJumpScroll } = {}) => render(
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
    historySeek={historySeek}
    onSeekTimeline={seekResult}
    onRestoreJump={onRestoreJump}
    onSettleJumpScroll={onSettleJumpScroll}
  >
    {split => (
      <div>
        {split.jumpButton}
        {split.jumpPanel}
      </div>
    )}
  </TimelineSplitControllerCore>,
);

const armScrollWait = async () => {
  fireEvent.click(screen.getByRole('button', { name: 'Find in this timeline' }));
  fireEvent.change(screen.getByLabelText('Date and time'), { target: { value: '2026-10-17T09:30' } });

  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Jump' }));
    await Promise.resolve();
  });
};

describe('timeline jump scroll confirmation', () => {
  let frames;

  beforeEach(() => {
    frames = [];
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
    jest.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => {
      frames[id - 1] = null;
    });
  });

  afterEach(() => {
    resetHistorySurfaces();
    jest.restoreAllMocks();
  });

  const flushFrames = () => {
    const batch = frames.splice(0, frames.length);

    act(() => {
      batch.forEach(callback => callback && callback(0));
    });
  };

  it('settles a wheel during the post-commit wait as cancelled_scroll and does not restore', async () => {
    const onRestoreJump = jest.fn();
    const onSettleJumpScroll = jest.fn();

    renderJump({ onRestoreJump, onSettleJumpScroll });
    await armScrollWait();
    emitHistorySurfaceScroll(splitId);
    await act(async () => {
      await Promise.resolve();
    });

    expect(onSettleJumpScroll).toHaveBeenCalledWith(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-1',
      revision: 2,
      scrolled: false,
      reason: 'user_scroll',
    }));
    expect(onRestoreJump).not.toHaveBeenCalled();
  });

  it('restores once on close while the scroll is unconfirmed and ignores a later settle', async () => {
    const onRestoreJump = jest.fn();
    const view = renderJump({ onRestoreJump, onSettleJumpScroll: jest.fn() });

    await armScrollWait();
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
    flushFrames();

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onRestoreJump.mock.calls[0][0]).toEqual(expect.objectContaining({
      splitTimelineId: splitId,
      sessionId: 'seek-1',
      reason: 'not_loaded',
      items,
      windowState,
    }));

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
        historySeek={pendingSeek.set('scrollStatus', 'filtered').set('scrollReason', 'filtered')}
        onSeekTimeline={seekResult}
        onRestoreJump={onRestoreJump}
        onSettleJumpScroll={jest.fn()}
      >
        {split => (
          <div>
            {split.jumpButton}
            {split.jumpPanel}
          </div>
        )}
      </TimelineSplitControllerCore>,
    );
    flushFrames();

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('restores once on unmount while waiting and a leftover frame does not restore again', async () => {
    const onRestoreJump = jest.fn();
    const view = renderJump({ onRestoreJump, onSettleJumpScroll: jest.fn() });

    await armScrollWait();
    view.unmount();
    flushFrames();
    flushFrames();

    expect(onRestoreJump).toHaveBeenCalledTimes(1);
    expect(onRestoreJump.mock.calls[0][0].reason).toBe('not_loaded');
  });
});

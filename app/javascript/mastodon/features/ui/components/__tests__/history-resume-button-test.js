/* eslint-disable react/prop-types, react/jsx-no-bind */

import { fireEvent, render } from '@testing-library/react';
import React from 'react';

import { captureHistoryPosition } from 'mastodon/actions/timeline_position';
import { historySourceIdentity, historyViewIdentity } from 'mastodon/timeline_position/identity';
import { resetPositionRegistry } from 'mastodon/timeline_position/session';
import { homeHistoryContract } from 'mastodon/windowed_history/sources';
import { TIMELINE_SPLIT_KEEP_LIVE } from '../timeline_split_controller_core';
import TimelineSplitControllerCore from '../timeline_split_controller_core';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

const contract = homeHistoryContract(['public']);

const anchor = {
  version: 1,
  statusId: '100',
  displayRowId: '100',
  offsetPx: 4,
  alignment: 'top',
  capturedAt: '2026-10-17T00:00:00.000Z',
};

const remember = () => captureHistoryPosition({
  accountId: '1',
  source: historySourceIdentity('home', contract),
  view: historyViewIdentity({
    columnId: 'column-a',
    sourceTimelineId: 'home',
    locationKey: 'entry-a',
  }),
  anchor,
  routeEntryKey: 'entry-a',
  sync: true,
});

const Harness = ({ activeSplitId = null, onCreate, onDestroy, onResumeHistory }) => (
  <TimelineSplitControllerCore
    sourceTimelineId='home'
    columnId='column-a'
    multiColumn={false}
    location={{ key: 'entry-a' }}
    accountId='1'
    historyContract={contract}
    activeSplitId={activeSplitId}
    splitRatio={50}
    unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Unavailable' }}
    onSplitRatioCommit={() => {}}
    onCreate={onCreate}
    onDestroy={onDestroy}
    onSaveReturnAnchor={() => {}}
    onClearReturnAnchor={() => {}}
    onCaptureHistoryPosition={captureHistoryPosition}
    onResumeHistory={onResumeHistory}
    onCancelHistoryResume={() => {}}
  >
    {split => (
      <div>
        {split.resumeButton}
        {split.splitButton}
        <button type='button' onClick={split.handleHeaderClick}>header</button>
      </div>
    )}
  </TimelineSplitControllerCore>
);

describe('history resume button', () => {
  beforeEach(() => {
    resetPositionRegistry();
  });

  it('offers an explicit resume and does not resume when History is closed back to Live', () => {
    remember();
    const onCreate = jest.fn();
    const onDestroy = jest.fn();
    const onResumeHistory = jest.fn();
    const view = render(
      <Harness onCreate={onCreate} onDestroy={onDestroy} onResumeHistory={onResumeHistory} />,
    );

    fireEvent.click(view.getByRole('button', { name: 'Resume saved place' }));
    expect(onCreate).toHaveBeenCalledTimes(1);
    expect(onResumeHistory).not.toHaveBeenCalled();

    view.rerender(
      <Harness
        activeSplitId={onCreate.mock.calls[0][0]}
        onCreate={onCreate}
        onDestroy={onDestroy}
        onResumeHistory={onResumeHistory}
      />,
    );

    expect(onResumeHistory).toHaveBeenCalledWith(expect.objectContaining({
      explicit: true,
      sourceTimelineId: 'home',
      splitTimelineId: onCreate.mock.calls[0][0],
    }));

    onResumeHistory.mockClear();
    fireEvent.click(view.getByRole('button', { name: 'Remove timeline split' }));

    expect(onDestroy).toHaveBeenCalledWith(onCreate.mock.calls[0][0], expect.objectContaining({
      keep: TIMELINE_SPLIT_KEEP_LIVE,
    }));
    expect(onResumeHistory).not.toHaveBeenCalled();
  });
});

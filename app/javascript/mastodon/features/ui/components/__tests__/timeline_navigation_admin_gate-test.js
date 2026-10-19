/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

const navigationRole = {
  isAdministrator: false,
};

jest.mock('mastodon/initial_state', () => {
  const actual = jest.requireActual('mastodon/initial_state');
  const state = { ...actual };

  // Object spread copies the boolean. A getter keeps later role changes visible.
  Object.defineProperty(state, 'isAdministrator', {
    configurable: true,
    enumerable: true,
    get: () => navigationRole.isAdministrator,
  });

  return state;
});

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({
    get: jest.fn(() => Promise.resolve({ data: [] })),
    post: jest.fn(() => Promise.resolve({ data: {} })),
  })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('react-intl', () => {
  const ReactIntl = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <ReactIntl.Fragment><Component {...props} intl={intl} /></ReactIntl.Fragment>,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import { captureHistoryPosition } from 'mastodon/actions/timeline_position';
import timelines from 'mastodon/reducers/timelines';
import { historySourceIdentity, historyViewIdentity } from 'mastodon/timeline_position/identity';
import { resetPositionRegistry } from 'mastodon/timeline_position/session';
import { homeHistoryContract } from 'mastodon/windowed_history/sources';
import StatusTimelineSplitController from '../status_timeline_split_controller';
import TimelineSplitControllerCore from '../timeline_split_controller_core';

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

const unavailableMessage = {
  id: 'timeline.split_unavailable',
  defaultMessage: 'Unavailable',
};

const SplitChrome = ({ split }) => (
  <div>
    {split.splitButton}
    {split.jumpButton}
    {split.jumpPanel}
    {split.bookmarkButton}
    {split.bookmarkPanel}
    {split.resumeButton}
    {split.splitter}
    {split.closeLiveButton}
  </div>
);

const buildStore = () => {
  const reducer = combineReducers({ timelines });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['timelines', 'home'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(),
    items: ImmutableList(['100', '90', '80']),
  }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderStatusTimeline = () => render(
  <Provider store={buildStore()}>
    <StatusTimelineSplitController
      sourceTimelineId='home'
      columnId='column-a'
      accountId='1'
      historyContract={contract}
      location={{ key: 'entry-a' }}
      multiColumn
      splitRatio={50}
      unavailableMessage={unavailableMessage}
      onSplitRatioCommit={() => {}}
    >
      {split => <SplitChrome split={split} />}
    </StatusTimelineSplitController>
  </Provider>,
);

const CoreHarness = ({
  timelineNavigationVisible,
  activeSplitId = null,
  onCreate = () => {},
}) => (
  <TimelineSplitControllerCore
    sourceTimelineId='home'
    columnId='column-a'
    multiColumn
    location={{ key: 'entry-a' }}
    accountId='1'
    historyContract={contract}
    activeSplitId={activeSplitId}
    splitRatio={50}
    unavailableMessage={unavailableMessage}
    onSplitRatioCommit={() => {}}
    onCreate={onCreate}
    onDestroy={() => {}}
    onSaveReturnAnchor={() => {}}
    onClearReturnAnchor={() => {}}
    onCaptureHistoryPosition={captureHistoryPosition}
    onResumeHistory={() => {}}
    onCancelHistoryResume={() => {}}
    onSeekTimeline={() => Promise.resolve({})}
    onListReadingBookmarks={() => Promise.resolve([])}
    onCreateReadingBookmark={() => Promise.resolve({})}
    {...(timelineNavigationVisible === undefined ? {} : { timelineNavigationVisible })}
  >
    {split => <SplitChrome split={split} />}
  </TimelineSplitControllerCore>
);

const expectNavigationAbsent = (view) => {
  expect(view.queryByRole('button', { name: 'Find in this timeline' })).toBeNull();
  expect(view.queryByRole('button', { name: 'Reading bookmarks' })).toBeNull();
  expect(view.queryByRole('button', { name: 'Resume saved place' })).toBeNull();
  expect(view.queryByRole('dialog')).toBeNull();
  expect(view.container.querySelector('.column-header__jump-button')).toBeNull();
  expect(view.container.querySelector('.column-header__bookmark-button')).toBeNull();
  expect(view.container.querySelector('.column-header__resume-button')).toBeNull();
  expect(view.container.querySelector('.timeline-jump')).toBeNull();
  expect(view.container.querySelector('.timeline-bookmarks')).toBeNull();
};

const expectSplitStillWorks = (view) => {
  fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));

  expect(view.getByRole('separator', { name: 'Timeline splitter' })).toBeTruthy();
  expect(view.getByRole('button', { name: 'Close live pane' })).toBeTruthy();
  expect(view.getByRole('button', { name: 'Close history pane' })).toBeTruthy();
};

describe('Timeline Navigation administrator gate', () => {
  beforeEach(() => {
    navigationRole.isAdministrator = false;
    resetPositionRegistry();
    remember();
  });

  it('shows jump, reading bookmarks, and resume to an administrator', async () => {
    navigationRole.isAdministrator = true;
    const view = renderStatusTimeline();

    expect(view.getByRole('button', { name: 'Find in this timeline' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Reading bookmarks' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Resume saved place' })).toBeTruthy();

    fireEvent.click(view.getByRole('button', { name: 'Find in this timeline' }));
    expect(view.getByRole('dialog', { name: 'Find in this timeline' })).toBeTruthy();
    expect(view.container.querySelector('.timeline-jump')).not.toBeNull();

    fireEvent.keyDown(view.getByRole('dialog', { name: 'Find in this timeline' }), { key: 'Escape' });
    expect(view.queryByRole('dialog', { name: 'Find in this timeline' })).toBeNull();

    await act(async () => {
      fireEvent.click(view.getByRole('button', { name: 'Reading bookmarks' }));
      await Promise.resolve();
    });

    expect(view.getByRole('dialog', { name: 'Reading bookmarks' })).toBeTruthy();
    expect(view.container.querySelector('.timeline-bookmarks')).not.toBeNull();
    expectSplitStillWorks(view);
    expect(view.getByRole('button', { name: 'Find in this timeline' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Reading bookmarks' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Resume saved place' })).toBeTruthy();
  });

  it('hides navigation controls from signed-out, regular, and moderator sessions and still splits', () => {
    // Those sessions all have isAdministrator === false. isStaff is not the gate.
    navigationRole.isAdministrator = false;
    const view = renderStatusTimeline();

    expectNavigationAbsent(view);
    expectSplitStillWorks(view);
    expectNavigationAbsent(view);
    expect(view.getByRole('button', { name: 'Remove timeline split' })).toHaveAttribute('aria-pressed', 'true');
  });

  it('keeps navigation controls when Core is used without the visibility prop', () => {
    const view = render(<CoreHarness />);

    expect(view.getByRole('button', { name: 'Find in this timeline' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Reading bookmarks' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Resume saved place' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Split timeline' })).toBeTruthy();
  });

  it('hides navigation controls when Core is passed timelineNavigationVisible false and still splits', () => {
    const onCreate = jest.fn();
    const view = render(<CoreHarness timelineNavigationVisible={false} onCreate={onCreate} />);

    expectNavigationAbsent(view);
    fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));
    expect(onCreate).toHaveBeenCalledTimes(1);

    view.rerender(
      <CoreHarness
        timelineNavigationVisible={false}
        onCreate={onCreate}
        activeSplitId={onCreate.mock.calls[0][0]}
      />,
    );

    expect(view.getByRole('separator', { name: 'Timeline splitter' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Close live pane' })).toBeTruthy();
    expectNavigationAbsent(view);
  });

  it('shows navigation controls when Core is passed timelineNavigationVisible true', () => {
    navigationRole.isAdministrator = false;
    const view = render(<CoreHarness timelineNavigationVisible />);

    expect(view.getByRole('button', { name: 'Find in this timeline' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Reading bookmarks' })).toBeTruthy();
    expect(view.getByRole('button', { name: 'Resume saved place' })).toBeTruthy();
  });
});

/* eslint-disable react/prop-types */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import settingsReducer from 'mastodon/reducers/settings';
import { groupPostingContext } from '../../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../../posting_context/fixtures/mitra_group_context_fixture';
import { nodebbGroupPostingContext } from '../../../posting_context/fixtures/nodebb_group_context_fixture';
import { lemmyGroupPostingContext } from '../../../posting_context/fixtures/threadiverse_group_context_fixture';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ put: jest.fn(() => Promise.resolve({ data: {} })) })),
}));

const mockFetchAccount = jest.fn(id => ({ type: 'ACCOUNT_FETCH', id }));
const mockFetchPostingContext = jest.fn(id => ({ type: 'POSTING_CONTEXT_FETCH', id }));

jest.mock('../../../actions/accounts', () => ({
  fetchAccount: (...args) => mockFetchAccount(...args),
}));

jest.mock('../../../actions/posting_contexts', () => ({
  fetchPostingContext: (...args) => mockFetchPostingContext(...args),
}));

jest.mock('../../../actions/timelines', () => ({
  expandGroupTimeline: () => ({ type: 'GROUP_TIMELINE_EXPAND' }),
  clearTimelineSplitReturnAnchor: () => ({ type: 'TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR' }),
}));

jest.mock('../../../actions/streaming', () => ({
  connectGroupStream: () => () => () => {},
}));

jest.mock('../../../components/column', () => {
  const React = require('react');
  return React.forwardRef(({ children }, ref) => <div ref={ref}>{children}</div>);
});
jest.mock('../../../components/column_header', () => ({ children, extraButton }) => <div>{extraButton}{children}</div>);
jest.mock('../../../components/icon', () => () => null);
jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../components/group_detail', () => () => null);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId }) {
    return <div data-testid='portable-composer' data-composer-id={composerId} />;
  };
});

const captured = [];

jest.mock('../../ui/containers/status_list_container', () => {
  const React = require('react');

  return function StatusListContainer (props) {
    captured.push(props);
    return <div data-testid='status-list'>{props.prepend}</div>;
  };
});

const localGroup = ImmutableMap({
  id: '123',
  username: 'group',
  acct: 'group',
  group: true,
  display_name: 'Group',
});

const remoteLookingGroup = ImmutableMap({
  id: '456',
  username: 'group',
  acct: 'group@example.com',
  group: true,
  display_name: 'Remote group',
});

const discoveryRecord = (status, context = null, reason = null) => fromJS({
  status,
  context,
  discovery: status === 'resolved' ? {
    mechanism: 'built_in',
    adapter: 'fedibird_group',
    authority: 'server',
  } : {
    mechanism: null,
    adapter: null,
    authority: null,
  },
  reason,
  error: null,
});

const loadTimeline = ({ isAdministrator = true, isStaff = false } = {}) => {
  let GroupTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      isAdministrator,
      isStaff,
    }));
    GroupTimeline = require('../index').default;
  });

  return GroupTimeline;
};

const withVisibility = (settingsState, visibility) => {
  if (!visibility) {
    return settingsState;
  }

  return Object.keys(visibility).reduce(
    (state, composerId) => state.setIn(['portableComposerVisibility', composerId], visibility[composerId]),
    settingsState,
  );
};

const renderTimeline = (GroupTimeline, {
  columnId,
  account = localGroup,
  accounts,
  onlyMedia = false,
  withoutMedia = false,
  tagged,
  discovery = discoveryRecord('resolved', groupPostingContext),
  visibility,
} = {}) => {
  captured.length = 0;
  const accountMap = accounts || ImmutableMap({
    [account.get('id')]: account,
  });
  const postingContexts = discovery ? accountMap.map(item => (
    item.get('id') === account.get('id') ? discovery : null
  )).filter(value => value) : ImmutableMap();
  let settingsState = withVisibility(settingsReducer(undefined, { type: '@@INIT' }), visibility);

  settingsState = settingsState.setIn(['group', 'other'], ImmutableMap({ onlyMedia, withoutMedia }));

  const initialState = ImmutableMap({
    accounts: accountMap,
    posting_contexts: postingContexts,
    timelines: ImmutableMap(),
    settings: settingsState,
  });
  const store = createStore((state = initialState, action) => {
    if (action && action.type === 'TEST_REPLACE') {
      return action.state;
    }

    if (action && (action.type === 'SETTING_CHANGE' || action.type === 'SETTING_SAVE')) {
      return state.set('settings', settingsReducer(state.get('settings'), action));
    }

    return state;
  }, initialState, applyMiddleware(thunk));

  const view = render(
    <Provider store={store}>
      <GroupTimeline params={{ id: account.get('id'), tagged }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return {
    props: captured[captured.length - 1],
    store,
    initialState,
    ...view,
  };
};

describe('GroupTimeline portable composer', () => {
  beforeEach(() => {
    mockFetchAccount.mockClear();
    mockFetchPostingContext.mockClear();
  });

  afterEach(() => {
    cleanup();
  });

  it('stays hidden until an administrator shows it, then mounts after the posting context resolves', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const view = renderTimeline(GroupTimeline, { discovery: null });

    expect(screen.getByRole('button', { name: 'Split timeline' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Show group detail' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Show composer' }).getAttribute('aria-pressed')).toBe('false');
    expect(mockFetchPostingContext).not.toHaveBeenCalled();
    expect(mockFetchAccount).toHaveBeenCalledWith('123');
    expect(view.props.prepend).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));

    expect(mockFetchPostingContext).toHaveBeenCalledTimes(1);
    expect(mockFetchPostingContext).toHaveBeenCalledWith('123');
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-route:123'])).toBe(true);
    expect(captured[captured.length - 1].prepend).toBeNull();

    view.store.dispatch({
      type: 'TEST_REPLACE',
      state: view.store.getState().setIn(['posting_contexts', '123'], discoveryRecord('resolved', groupPostingContext)),
    });

    const shown = captured[captured.length - 1];

    expect(shown.alwaysPrepend).toBe(true);
    expect(shown.prepend.props.composerId).toEqual('portable:group-route:123');
    expect(shown.prepend.key).toEqual('portable:group-route:123');
    expect(shown.prepend.props.postingContext).toEqual(groupPostingContext);
    expect(shown.prepend.props.postingContext.discovery).toBeUndefined();
    expect(screen.getByRole('button', { name: 'Hide composer' }).getAttribute('aria-pressed')).toBe('true');

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));

    expect(captured[captured.length - 1].prepend).toBeNull();
    expect(captured[captured.length - 1].alwaysPrepend).toBe(false);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-route:123'])).toBe(false);
  });

  it('prepends a visible composer from a resolved discovery result', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const route = renderTimeline(GroupTimeline, {
      visibility: { 'portable:group-route:123': true },
    });

    cleanup();
    const column = renderTimeline(GroupTimeline, {
      columnId: 'column-1',
      visibility: { 'portable:group-column:column-1': true },
    });
    const context = route.props.prepend.props.postingContext;

    expect(mockFetchPostingContext).toHaveBeenCalledWith('123');
    expect(mockFetchAccount).toHaveBeenCalledWith('123');
    expect(route.props.alwaysPrepend).toBe(true);
    expect(route.props.prepend.props.composerId).toEqual('portable:group-route:123');
    expect(route.props.prepend.key).toEqual('portable:group-route:123');
    expect(context).toEqual(groupPostingContext);
    expect(context.discovery).toBeUndefined();
    expect(route.props.prepend.props.postingContextAccountId).toEqual('123');
    expect(column.props.prepend.props.postingContextAccountId).toEqual('123');
    expect(column.props.prepend.props.composerId).toEqual('portable:group-column:column-1');
    expect(column.props.prepend.key).toEqual('portable:group-column:column-1');
    expect(column.props.alwaysPrepend).toBe(true);
  });

  it('keeps timeline filters out of the posting context and does not rediscover them', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const plain = renderTimeline(GroupTimeline, {
      visibility: { 'portable:group-route:123': true },
    });
    const callsAfterMount = mockFetchPostingContext.mock.calls.length;

    plain.store.dispatch({
      type: 'TEST_REPLACE',
      state: plain.initialState.setIn(['settings', 'group', 'other', 'onlyMedia'], true),
    });

    const filtered = captured[captured.length - 1];

    expect(mockFetchPostingContext.mock.calls.length).toEqual(callsAfterMount);
    expect(filtered.prepend.props.composerId).toEqual(plain.props.prepend.props.composerId);
    expect(filtered.prepend.props.postingContext).toEqual(plain.props.prepend.props.postingContext);
  });

  it('refetches the account and discovery result when a visible group id changes', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const accounts = ImmutableMap({
      '123': localGroup,
      '456': remoteLookingGroup,
    });
    const view = renderTimeline(GroupTimeline, {
      account: localGroup,
      accounts,
      discovery: discoveryRecord('resolved', groupPostingContext),
      visibility: {
        'portable:group-route:123': true,
        'portable:group-route:456': true,
      },
    });

    view.rerender(
      <Provider store={view.store}>
        <GroupTimeline params={{ id: '456' }} multiColumn={false} />
      </Provider>,
    );

    expect(mockFetchAccount).toHaveBeenCalledWith('456');
    expect(mockFetchPostingContext).toHaveBeenCalledWith('456');
  });

  it('does not fetch a group whose composer is hidden', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const accounts = ImmutableMap({
      '123': localGroup,
      '456': remoteLookingGroup,
    });
    const view = renderTimeline(GroupTimeline, {
      account: localGroup,
      accounts,
      visibility: {
        'portable:group-route:123': false,
        'portable:group-route:456': false,
      },
    });

    expect(mockFetchPostingContext).not.toHaveBeenCalled();
    expect(view.props.prepend).toBeNull();

    view.rerender(
      <Provider store={view.store}>
        <GroupTimeline params={{ id: '456' }} multiColumn={false} />
      </Provider>,
    );

    expect(mockFetchPostingContext).not.toHaveBeenCalled();
    expect(captured[captured.length - 1].prepend).toBeNull();
    expect(mockFetchAccount).toHaveBeenCalledWith('456');
  });

  it('fetches a newly selected group when that composer was saved as visible', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const accounts = ImmutableMap({
      '123': localGroup,
      '456': remoteLookingGroup,
    });
    const view = renderTimeline(GroupTimeline, {
      account: localGroup,
      accounts,
      visibility: {
        'portable:group-route:123': false,
        'portable:group-route:456': true,
      },
    });

    expect(mockFetchPostingContext).not.toHaveBeenCalled();

    view.store.dispatch({
      type: 'TEST_REPLACE',
      state: view.store.getState().setIn(['posting_contexts', '456'], discoveryRecord('resolved', {
        ...groupPostingContext,
        key: 'builtin:fedibird-group:456',
      })),
    });
    mockFetchPostingContext.mockClear();

    view.rerender(
      <Provider store={view.store}>
        <GroupTimeline params={{ id: '456' }} multiColumn={false} />
      </Provider>,
    );

    expect(mockFetchPostingContext).toHaveBeenCalledTimes(1);
    expect(mockFetchPostingContext).toHaveBeenCalledWith('456');
    expect(captured[captured.length - 1].prepend.props.composerId).toEqual('portable:group-route:456');
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-route:123'])).toBe(false);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-route:456'])).toBe(true);
  });

  it('hides the composer when discovery is unsupported, including a local-looking group', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const props = renderTimeline(GroupTimeline, {
      discovery: discoveryRecord('unsupported', null, 'no_supported_adapter'),
      visibility: { 'portable:group-route:123': true },
    }).props;

    expect(mockFetchPostingContext).toHaveBeenCalledWith('123');
    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('hides the composer for a remote-looking group when discovery is unsupported', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const props = renderTimeline(GroupTimeline, {
      account: remoteLookingGroup,
      discovery: discoveryRecord('unsupported', null, 'no_supported_adapter'),
      visibility: { 'portable:group-route:456': true },
    }).props;

    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('shows the composer for a remote-looking group when discovery is resolved', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const props = renderTimeline(GroupTimeline, {
      account: remoteLookingGroup,
      discovery: discoveryRecord('resolved', {
        ...groupPostingContext,
        key: 'builtin:fedibird-group:456',
      }),
      visibility: { 'portable:group-route:456': true },
    }).props;

    expect(props.prepend.props.composerId).toEqual('portable:group-route:456');
    expect(props.prepend.props.postingContext.key).toEqual('builtin:fedibird-group:456');
    expect(props.prepend.props.postingContext.discovery).toBeUndefined();
  });

  it('keeps the timeline without a composer while discovery is missing, loading, or failed', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });

    ['loading', 'not_applicable', 'error'].forEach(status => {
      cleanup();
      mockFetchPostingContext.mockClear();
      const view = renderTimeline(GroupTimeline, {
        discovery: status === 'not_applicable' ? discoveryRecord(status, null, 'not_group') : discoveryRecord(status),
        visibility: { 'portable:group-route:123': true },
      });

      expect(mockFetchPostingContext).toHaveBeenCalledWith('123');
      expect(view.container.querySelector('[data-testid="status-list"]')).not.toBeNull();
      expect(view.props.prepend).toBeNull();
    });

    cleanup();
    const missing = renderTimeline(GroupTimeline, {
      discovery: null,
      visibility: { 'portable:group-route:123': true },
    });

    expect(missing.container.querySelector('[data-testid="status-list"]')).not.toBeNull();
    expect(missing.props.prepend).toBeNull();
  });

  it('prepends a visible composer for a resolved remote group audience', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const account = ImmutableMap({
      id: '456',
      username: 'group',
      acct: 'group@mitra.example',
      group: true,
      display_name: 'Remote group',
    });
    const props = renderTimeline(GroupTimeline, {
      account,
      discovery: discoveryRecord('resolved', mitraGroupPostingContext),
      visibility: { 'portable:group-route:456': true },
    }).props;

    expect(mockFetchPostingContext).toHaveBeenCalledWith('456');
    expect(props.alwaysPrepend).toBe(true);
    expect(props.prepend.props.composerId).toEqual('portable:group-route:456');
    expect(props.prepend.props.postingContext.protocol.activityPub.audience).toEqual({
      accountId: '456',
      acct: 'group@mitra.example',
      enforcement: 'required',
      ruleId: 'fep-1b12-group-audience',
    });
    expect(props.prepend.props.postingContext.managed.mentions).toEqual([]);
    expect(props.prepend.props.postingContext.requirements.followingAccounts).toEqual([]);
    expect(props.prepend.props.postingContext.constraints.allowedVisibilities).toEqual(['public', 'unlisted']);
  });

  it('prepends a NodeBB category context with its required mention and public-only constraint', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const account = ImmutableMap({
      id: '456',
      username: 'category',
      acct: 'category@nodebb.example',
      group: true,
      display_name: 'Category',
    });
    const props = renderTimeline(GroupTimeline, {
      account,
      discovery: discoveryRecord('resolved', nodebbGroupPostingContext),
      visibility: { 'portable:group-route:456': true },
    }).props;

    expect(props.prepend.props.composerId).toEqual('portable:group-route:456');
    expect(props.prepend.props.postingContextAccountId).toEqual('456');
    expect(props.prepend.props.postingContext.key).toEqual('protocol:fep-1b12-nodebb:456');
    expect(props.prepend.props.postingContext.constraints.allowedVisibilities).toEqual(['public']);
    expect(props.prepend.props.postingContext.managed.mentions).toEqual([
      {
        accountId: '456',
        acct: 'category@nodebb.example',
        enforcement: 'required',
        ruleId: 'nodebb-group-mention',
      },
    ]);
    expect(props.prepend.props.postingContext.protocol.activityPub.audience.accountId).toEqual('456');
  });

  it('prepends a Lemmy community context with an appended mention', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const account = ImmutableMap({
      id: '456',
      username: 'technology',
      acct: 'technology@lemmy.example',
      group: true,
      display_name: 'Technology',
    });
    const props = renderTimeline(GroupTimeline, {
      account,
      discovery: discoveryRecord('resolved', lemmyGroupPostingContext),
      visibility: { 'portable:group-route:456': true },
    }).props;

    expect(props.prepend.props.postingContext.key).toEqual('protocol:fep-1b12-lemmy:456');
    expect(props.prepend.props.postingContext.managed.mentions).toEqual([
      {
        accountId: '456',
        acct: 'technology@lemmy.example',
        enforcement: 'required',
        ruleId: 'lemmy-group-mention',
        placement: 'append',
      },
    ]);
    expect(props.prepend.props.postingContext.constraints.allowedVisibilities).toEqual(['public']);
  });

  it('keeps the composer mounted while a resolved context is refreshing', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: true });
    const view = renderTimeline(GroupTimeline, {
      visibility: { 'portable:group-route:123': true },
    });

    expect(screen.getByTestId('portable-composer')).toBeTruthy();

    view.store.dispatch({
      type: 'TEST_REPLACE',
      state: view.store.getState().setIn(['posting_contexts', '123', 'refreshing'], true),
    });

    expect(screen.getByTestId('portable-composer')).toBeTruthy();
    expect(captured[captured.length - 1].prepend.props.postingContext.key).toEqual('builtin:fedibird-group:123');
    expect(captured[captured.length - 1].prepend.props.postingContextAccountId).toEqual('123');
  });

  it('does not fetch or mount a composer for a non-administrator', () => {
    const GroupTimeline = loadTimeline({ isAdministrator: false, isStaff: true });
    const props = renderTimeline(GroupTimeline, {
      visibility: { 'portable:group-route:123': true },
    }).props;

    expect(mockFetchPostingContext).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Show composer' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Hide composer' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Show group detail' })).toBeTruthy();
    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });
});

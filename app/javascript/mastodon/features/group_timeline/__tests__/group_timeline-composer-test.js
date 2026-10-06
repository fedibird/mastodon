/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import { groupPostingContext } from '../../../posting_context/__tests__/group_context_fixture';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

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
}));

jest.mock('../../../actions/streaming', () => ({
  connectGroupStream: () => () => () => {},
}));

jest.mock('../../../components/column', () => {
  const React = require('react');
  return React.forwardRef(({ children }, ref) => <div ref={ref}>{children}</div>);
});
jest.mock('../../../components/column_header', () => ({ children }) => <div>{children}</div>);
jest.mock('../../../components/icon', () => () => null);
jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../components/group_detail', () => () => null);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer () {
    return <div data-testid='portable-composer' />;
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

const loadTimeline = (policy) => {
  let GroupTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      new_features_policy: policy,
    }));
    GroupTimeline = require('../index').default;
  });

  return GroupTimeline;
};

const renderTimeline = (GroupTimeline, {
  columnId,
  account = localGroup,
  accounts,
  onlyMedia = false,
  withoutMedia = false,
  tagged,
  discovery = discoveryRecord('resolved', groupPostingContext),
} = {}) => {
  captured.length = 0;
  const accountMap = accounts || ImmutableMap({
    [account.get('id')]: account,
  });
  const postingContexts = discovery ? accountMap.map(item => (
    item.get('id') === account.get('id') ? discovery : null
  )).filter(value => value) : ImmutableMap();
  const initialState = ImmutableMap({
    accounts: accountMap,
    posting_contexts: postingContexts,
    timelines: ImmutableMap(),
    settings: ImmutableMap({
      columns: ImmutableList(),
      group: ImmutableMap({
        other: ImmutableMap({ onlyMedia, withoutMedia }),
      }),
    }),
  });
  const store = createStore((state = initialState, action) => (
    action && action.type === 'TEST_REPLACE' ? action.state : state
  ), initialState, applyMiddleware(thunk));

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

  it('prepends a tester composer from a resolved discovery result', () => {
    const GroupTimeline = loadTimeline('tester');
    const route = renderTimeline(GroupTimeline);
    const column = renderTimeline(GroupTimeline, { columnId: 'column-1' });
    const context = route.props.prepend.props.postingContext;

    expect(mockFetchPostingContext).toHaveBeenCalledWith('123');
    expect(mockFetchAccount).toHaveBeenCalledWith('123');
    expect(route.props.alwaysPrepend).toBe(true);
    expect(route.props.prepend.props.composerId).toEqual('portable:group-route:123');
    expect(route.props.prepend.key).toEqual('portable:group-route:123');
    expect(context).toEqual(groupPostingContext);
    expect(context.discovery).toBeUndefined();
    expect(column.props.prepend.props.composerId).toEqual('portable:group-column:column-1');
    expect(column.props.prepend.key).toEqual('portable:group-column:column-1');
    expect(column.props.alwaysPrepend).toBe(true);
  });

  it('keeps timeline filters out of the posting context and does not rediscover them', () => {
    const GroupTimeline = loadTimeline('tester');
    const plain = renderTimeline(GroupTimeline);
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

  it('refetches the account and discovery result when the group id changes', () => {
    const GroupTimeline = loadTimeline('tester');
    const accounts = ImmutableMap({
      '123': localGroup,
      '456': remoteLookingGroup,
    });
    const view = renderTimeline(GroupTimeline, {
      account: localGroup,
      accounts,
      discovery: discoveryRecord('resolved', groupPostingContext),
    });

    view.rerender(
      <Provider store={view.store}>
        <GroupTimeline params={{ id: '456' }} multiColumn={false} />
      </Provider>,
    );

    expect(mockFetchAccount).toHaveBeenCalledWith('456');
    expect(mockFetchPostingContext).toHaveBeenCalledWith('456');
  });

  it('hides the composer when discovery is unsupported, including a local-looking group', () => {
    const GroupTimeline = loadTimeline('tester');
    const props = renderTimeline(GroupTimeline, {
      discovery: discoveryRecord('unsupported', null, 'no_supported_adapter'),
    }).props;

    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('hides the composer for a remote-looking group when discovery is unsupported', () => {
    const GroupTimeline = loadTimeline('tester');
    const props = renderTimeline(GroupTimeline, {
      account: remoteLookingGroup,
      discovery: discoveryRecord('unsupported', null, 'no_supported_adapter'),
    }).props;

    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('shows the composer for a remote-looking group when discovery is resolved', () => {
    const GroupTimeline = loadTimeline('tester');
    const props = renderTimeline(GroupTimeline, {
      account: remoteLookingGroup,
      discovery: discoveryRecord('resolved', {
        ...groupPostingContext,
        key: 'builtin:fedibird-group:456',
      }),
    }).props;

    expect(props.prepend.props.composerId).toEqual('portable:group-route:456');
    expect(props.prepend.props.postingContext.key).toEqual('builtin:fedibird-group:456');
    expect(props.prepend.props.postingContext.discovery).toBeUndefined();
  });

  it('keeps the timeline without a composer while discovery is missing, loading, or failed', () => {
    const GroupTimeline = loadTimeline('tester');

    ['loading', 'not_applicable', 'error'].forEach(status => {
      const view = renderTimeline(GroupTimeline, {
        discovery: status === 'not_applicable' ? discoveryRecord(status, null, 'not_group') : discoveryRecord(status),
      });

      expect(view.getByTestId('status-list')).toBeTruthy();
      expect(view.props.prepend).toBeNull();
    });

    const missing = renderTimeline(GroupTimeline, { discovery: null });

    expect(missing.getByTestId('status-list')).toBeTruthy();
    expect(missing.props.prepend).toBeNull();
  });

  it('does not fetch or prepend a composer for default or conservative policy', () => {
    ['default', 'conservative'].forEach(policy => {
      mockFetchPostingContext.mockClear();
      const props = renderTimeline(loadTimeline(policy)).props;

      expect(mockFetchPostingContext).not.toHaveBeenCalled();
      expect(props.prepend).toBeNull();
      expect(props.alwaysPrepend).toBe(false);
    });
  });
});

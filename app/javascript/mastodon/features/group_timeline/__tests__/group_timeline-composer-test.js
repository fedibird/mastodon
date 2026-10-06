/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../../actions/accounts', () => ({
  fetchAccount: id => ({ type: 'ACCOUNT_FETCH', id }),
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

const renderTimeline = (GroupTimeline, { columnId, account = localGroup, onlyMedia = false, withoutMedia = false, tagged } = {}) => {
  captured.length = 0;
  const store = createStore(() => ImmutableMap({
    accounts: ImmutableMap({
      [account.get('id')]: account,
    }),
    timelines: ImmutableMap(),
    settings: ImmutableMap({
      columns: ImmutableList(),
      group: ImmutableMap({
        other: ImmutableMap({ onlyMedia, withoutMedia }),
      }),
    }),
  }), applyMiddleware(thunk));

  render(
    <Provider store={store}>
      <GroupTimeline params={{ id: account.get('id'), tagged }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return captured[captured.length - 1];
};

describe('GroupTimeline portable composer', () => {
  it('prepends a tester composer for a local Fedibird group', () => {
    const GroupTimeline = loadTimeline('tester');
    const routeProps = renderTimeline(GroupTimeline);
    const columnProps = renderTimeline(GroupTimeline, { columnId: 'column-1' });
    const context = routeProps.prepend.props.postingContext;

    expect(routeProps.alwaysPrepend).toBe(true);
    expect(routeProps.prepend.props.composerId).toEqual('portable:group-route:123');
    expect(routeProps.prepend.key).toEqual('portable:group-route:123');
    expect(context.managed.mentions[0]).toEqual({
      accountId: '123',
      acct: 'group',
      enforcement: 'required',
      ruleId: 'group-account-mention',
    });
    expect(context.requirements.followingAccounts[0]).toEqual({
      accountId: '123',
      acct: 'group',
      enforcement: 'required',
      ruleId: 'group-follow',
    });
    expect(context.constraints.allowedVisibilities).toEqual(['public', 'unlisted']);
    expect(columnProps.prepend.props.composerId).toEqual('portable:group-column:column-1');
    expect(columnProps.prepend.key).toEqual('portable:group-column:column-1');
    expect(columnProps.alwaysPrepend).toBe(true);
  });

  it('keeps timeline filters out of the posting context', () => {
    const GroupTimeline = loadTimeline('tester');
    const plain = renderTimeline(GroupTimeline);
    const filtered = renderTimeline(GroupTimeline, { tagged: 'news', onlyMedia: true, withoutMedia: true });

    expect(filtered.prepend.props.composerId).toEqual(plain.prepend.props.composerId);
    expect(filtered.prepend.props.postingContext).toEqual(plain.prepend.props.postingContext);
  });

  it('does not prepend a composer for a remote group', () => {
    const GroupTimeline = loadTimeline('tester');
    const remote = ImmutableMap({
      id: '123',
      username: 'group',
      acct: 'group@example.com',
      group: true,
      display_name: 'Remote group',
    });
    const props = renderTimeline(GroupTimeline, { account: remote });

    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('does not prepend a composer for default or conservative policy', () => {
    ['default', 'conservative'].forEach(policy => {
      const props = renderTimeline(loadTimeline(policy));

      expect(props.prepend).toBeNull();
      expect(props.alwaysPrepend).toBe(false);
    });
  });
});

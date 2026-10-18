/**
 * @jest-environment jsdom
 */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

const flags = {
  isAdministrator: false,
  isStaff: false,
};

jest.mock('mastodon/initial_state', () => ({
  get isAdministrator () {
    return flags.isAdministrator;
  },
  get isStaff () {
    return flags.isStaff;
  },
}));

jest.mock('react-intl', () => {
  const React = require('react');

  return {
    injectIntl: Component => props => <Component {...props} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import AccountContextActions from '../components/actions';
import ReblogWrapperLink from '../components/reblog_wrapper_link';

const quotedBoost = fromJS({
  id: '100000000000000001',
  account: { id: '7' },
  reblog: {
    id: '100000000000000002',
    account: { id: '8' },
    quote_id: '100000000000000003',
    status_reference_ids: ['100000000000000004'],
  },
});

const store = createStore(state => state, {});

const renderActions = (onOpen = jest.fn()) => render(
  <AccountContextActions status={quotedBoost} hostTimelineId='home:split:column:session' onOpen={onOpen} />,
);

const renderReblogLink = () => render(
  <Provider store={store}>
    <div className='account-context-reblog-row'>
      <ReblogWrapperLink accountId='7' originalStatusId='100000000000000099' hostTimelineId='reblogs:column:100000000000000099' />
    </div>
  </Provider>,
);

describe('account context entry visibility', () => {
  beforeEach(() => {
    flags.isAdministrator = false;
    flags.isStaff = false;
  });

  it('shows boost, quote, and reference links to an administrator', () => {
    flags.isAdministrator = true;
    const onOpen = jest.fn();
    const { container } = renderActions(onOpen);

    expect(screen.getByRole('button', { name: 'See posts around this boost' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'See posts around this quote' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'See posts around this reference' })).toBeTruthy();
    expect(container.querySelector('.account-context-actions')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'See posts around this boost' }));

    expect(onOpen).toHaveBeenCalledWith('home:split:column:session', expect.objectContaining({
      available: true,
      kind: 'boost',
      statusId: '100000000000000001',
      accountId: '7',
    }));
  });

  it('shows the booster-list link to an administrator', () => {
    flags.isAdministrator = true;
    const { container } = renderReblogLink();

    expect(screen.getByRole('button', { name: 'See posts around this boost' })).toBeTruthy();
    expect(container.querySelector('.account-context-reblog')).not.toBeNull();
  });

  it.each([
    ['a regular account', false, false],
    ['a moderator', false, true],
    ['a signed-out session', undefined, false],
    ['a truthy non-boolean flag', 'true', true],
  ])('renders no entry and no spacing node for %s', (_label, isAdministrator, isStaff) => {
    flags.isAdministrator = isAdministrator;
    flags.isStaff = isStaff;

    const actions = renderActions();
    const reblogs = renderReblogLink();

    expect(actions.container.querySelector('.account-context-actions')).toBeNull();
    expect(actions.container.querySelector('.account-context-link')).toBeNull();
    expect(actions.container).toBeEmptyDOMElement();
    expect(reblogs.container.querySelector('.account-context-reblog')).toBeNull();
    expect(reblogs.container.querySelector('.account-context-link')).toBeNull();
    expect(reblogs.container.querySelector('.account-context-reblog-row')).toBeEmptyDOMElement();
    expect(screen.queryAllByRole('button')).toHaveLength(0);

    actions.unmount();
    reblogs.unmount();
  });
});

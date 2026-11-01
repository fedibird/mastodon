jest.mock('react-intl', () => {
  const React = require('react');
  const formatMessage = ({ defaultMessage }) => defaultMessage;

  return {
    defineMessages: (messages) => messages,
    injectIntl: (Component) => (props) => React.createElement(Component, { ...props, intl: { formatMessage } }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import GroupDirectoryFilterForm from '../components/filter_form';

const renderForm = (props) => render(
  <GroupDirectoryFilterForm
    viewKey={props.viewKey}
    params={{ order: 'active', scope: 'all', software: '', q: '', ...props.params }}
    signedIn={props.signedIn}
    onChange={props.onChange}
  />,
);

describe('GroupDirectoryFilterForm', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('keeps two columns on separate controls and commits search after a short pause', () => {
    const onLeft = jest.fn();
    const onRight = jest.fn();
    render(
      <div>
        <GroupDirectoryFilterForm viewKey='column:left' params={{ order: 'active', scope: 'all', software: '', q: '' }} signedIn onChange={onLeft} />
        <GroupDirectoryFilterForm viewKey='column:right' params={{ order: 'new', scope: 'local', software: '', q: 'books' }} signedIn onChange={onRight} />
      </div>,
    );

    const orders = screen.getAllByRole('radio', { name: 'Newly found', hidden: true });
    expect(orders).toHaveLength(2);
    expect(orders[0].name).not.toEqual(orders[1].name);
    expect(orders[0].checked).toBe(false);
    expect(orders[1].checked).toBe(true);
    expect(screen.queryByRole('combobox', { name: 'Implementation' })).toBeNull();

    fireEvent.click(screen.getAllByRole('button', { name: 'More filters' })[0]);
    expect(screen.getAllByRole('combobox', { name: 'Implementation' })).toHaveLength(1);

    fireEvent.click(orders[0]);
    expect(onLeft).toHaveBeenCalledWith({ order: 'new' });
    expect(onRight).not.toHaveBeenCalled();

    const search = screen.getAllByRole('searchbox', { name: 'Search groups' })[0];
    fireEvent.change(search, { target: { value: '写真' } });
    expect(onLeft).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(299);
    expect(onLeft).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(1);
    expect(onLeft).toHaveBeenCalledWith({ q: '写真' });

    fireEvent.change(search, { target: { value: '写真サークル' } });
    fireEvent.keyDown(search, { key: 'Enter' });
    expect(onLeft).toHaveBeenCalledWith({ q: '写真サークル' });
  });

  it('clears the search immediately and disables following when logged out', () => {
    const onChange = jest.fn();
    renderForm({ viewKey: 'route', signedIn: false, params: { q: 'books' }, onChange });

    const following = screen.getByRole('radio', { name: 'Following', hidden: true });
    expect(following.disabled).toBe(true);
    expect(following.closest('label').getAttribute('title')).toEqual('Log in to filter by groups you follow');

    fireEvent.change(screen.getByRole('searchbox', { name: 'Search groups' }), { target: { value: '' } });
    expect(onChange).toHaveBeenCalledWith({ q: '' });
  });
});

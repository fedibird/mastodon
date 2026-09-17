/* eslint-disable react/prop-types */

import { render, fireEvent, screen, waitFor } from '@testing-library/react';
import React from 'react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/components/icon_button', () => {
  const React = require('react');
  return ({ title, onClick }) => (
    <button type='button' title={title} onClick={onClick}>{title}</button>
  );
});

jest.mock('mastodon/components/icon', () => {
  const React = require('react');
  return ({ id }) => <span data-testid={`icon-${id}`} />;
});

jest.mock('react-intl', () => {
  const React = require('react');
  const interpolate = (defaultMessage, values, asString) => {
    if (!values) return defaultMessage;
    const parts = defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    ));
    return asString ? parts.join('') : parts;
  };
  const intl = {
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values, true),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

const mockFetchFilters = jest.fn(() => ({ type: 'FILTERS_FETCH_REQUEST' }));
const mockCreateFilter = jest.fn();
const mockCreateFilterStatus = jest.fn();

jest.mock('mastodon/actions/filters', () => ({
  fetchFilters: (...args) => mockFetchFilters(...args),
  createFilter: (...args) => mockCreateFilter(...args),
  createFilterStatus: (...args) => mockCreateFilterStatus(...args),
}));

import FilterModal from '../filter_modal';

const filters = {
  1: {
    id: '1',
    title: 'spoilers',
    keywords: [{ keyword: 'foo' }],
    context: ['home', 'public'],
    filter_action: 'warn',
    expires_at: null,
  },
  2: {
    id: '2',
    title: 'expired',
    keywords: [{ keyword: 'old' }],
    context: ['home'],
    filter_action: 'warn',
    expires_at: Date.parse('2000-01-01T00:00:00.000Z'),
  },
};

const store = createStore(() => fromJS({ filters }));

const renderModal = (props = {}) => render(
  <Provider store={store}>
    <FilterModal
      statusId='s1'
      contextType='home'
      onClose={jest.fn()}
      {...props}
    />
  </Provider>,
);

describe('FilterModal', () => {
  beforeEach(() => {
    mockFetchFilters.mockClear();
    mockCreateFilter.mockReset();
    mockCreateFilterStatus.mockReset();
  });

  it('fetches filters on mount and lists existing categories', () => {
    renderModal();

    expect(mockFetchFilters).toHaveBeenCalled();
    expect(screen.getByText('Filter this post')).toBeInTheDocument();
    expect(screen.getByText('spoilers')).toBeInTheDocument();
    expect(screen.getByText(/Expired/)).toBeInTheDocument();
  });

  it('attaches the status to a selected filter', async () => {
    mockCreateFilterStatus.mockImplementation((params, onSuccess) => {
      onSuccess({ id: 'fs1' });
      return { type: 'FILTERS_STATUS_CREATE_SUCCESS' };
    });

    renderModal();
    fireEvent.click(screen.getByText('spoilers'));

    expect(mockCreateFilterStatus).toHaveBeenCalledWith(
      { filter_id: '1', status_id: 's1' },
      expect.any(Function),
      expect.any(Function),
    );

    await waitFor(() => {
      expect(screen.getByText('Filter added!')).toBeInTheDocument();
    });
    expect(screen.getByText(/“spoilers”/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Go to filter settings' })).toHaveAttribute('href', '/filters/1/edit');
  });

  it('creates a new category then attaches the status', async () => {
    mockCreateFilter.mockImplementation((params, onSuccess) => {
      onSuccess({ id: '9' });
      return { type: 'FILTERS_CREATE_SUCCESS' };
    });
    mockCreateFilterStatus.mockImplementation((params, onSuccess) => {
      onSuccess({ id: 'fs9' });
      return { type: 'FILTERS_STATUS_CREATE_SUCCESS' };
    });

    renderModal();
    fireEvent.change(screen.getByPlaceholderText('Search or create'), { target: { value: 'new cat' } });
    fireEvent.click(screen.getByText('Create new filter category “new cat”'));

    expect(mockCreateFilter).toHaveBeenCalledWith({
      title: 'new cat',
      context: ['home', 'notifications', 'public', 'thread', 'account'],
      filter_action: 'warn',
    }, expect.any(Function), expect.any(Function));
    expect(mockCreateFilterStatus).toHaveBeenCalledWith(
      { filter_id: '9', status_id: 's1' },
      expect.any(Function),
      expect.any(Function),
    );
  });

  it('stays on the select step when attaching a status fails', async () => {
    mockCreateFilterStatus.mockImplementation((params, onSuccess, onFail) => {
      onFail(new Error('nope'));
      return { type: 'FILTERS_STATUS_CREATE_FAIL' };
    });

    renderModal();
    fireEvent.click(screen.getByText('spoilers'));

    await waitFor(() => {
      expect(screen.getByText('spoilers')).toBeInTheDocument();
    });
    expect(screen.queryByText('Filter added!')).not.toBeInTheDocument();
  });
});

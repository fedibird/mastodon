import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('mastodon/api', () => () => ({
  get: (...args) => mockGet(...args),
  post: (...args) => mockPost(...args),
  put: (...args) => mockPut(...args),
  delete: (...args) => mockDelete(...args),
}));

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
    formatTime: () => '3:00 PM',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

import filtersReducer from 'mastodon/reducers/filters';
import HashtagMuteModal from '../hashtag_mute_modal';

function reducer(state = fromJS({ filters: {} }), action) {
  if (action.type === 'MODAL_CLOSE') {
    return state.set('closed', true);
  }

  return state.set('filters', filtersReducer(state.get('filters'), action));
}

function renderModal(hashtag = '番組') {
  const store = createStore(reducer, undefined, applyMiddleware(thunk));

  render(
    <Provider store={store}>
      <MemoryRouter>
        <HashtagMuteModal hashtag={hashtag} />
      </MemoryRouter>
    </Provider>,
  );

  return store;
}

describe('HashtagMuteModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockGet.mockResolvedValue({ data: [] });
    mockPost.mockResolvedValue({ data: { id: '9', title: '#番組', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [], statuses: [], tags: [{ id: '1', name: '番組' }] } });
    mockPut.mockResolvedValue({ data: { id: '9', title: '#番組', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [], statuses: [], tags: [{ id: '1', name: '番組' }] } });
    mockDelete.mockResolvedValue({ data: {} });
  });

  it('confirms the tag, the default indefinite duration, and every place before saving', async () => {
    renderModal();

    const duration = await screen.findByLabelText(/Duration/);
    const values = Array.from(duration.options).map(option => option.value);

    expect(values).toEqual(['0', '300', '1800', '3600', '7200', '10800', '21600', '86400', '259200', '604800']);
    expect(duration).toHaveValue('0');
    expect(screen.getByText('Home and lists')).toBeTruthy();
    expect(screen.getByText('Notifications')).toBeTruthy();
    expect(screen.getByText('Public and other timelines')).toBeTruthy();
    expect(screen.getByText('Conversations')).toBeTruthy();
    expect(screen.getByText('Profiles')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Change where this applies' })).toHaveAttribute('href', '/settings/filters');

    await waitFor(() => expect(screen.getByRole('button', { name: 'Mute' })).not.toBeDisabled());
    fireEvent.change(duration, { target: { value: '10800' } });
    fireEvent.click(screen.getByRole('button', { name: 'Mute' }));

    await waitFor(() => expect(mockPost).toHaveBeenCalledWith('/api/v1/hashtag_mutes', { name: '番組', expires_in: 10800 }));
  });

  it('updates an existing mute in place and can remove it', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home', 'thread'],
        filter_action: 'hide',
        expires_at: null,
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await waitFor(() => expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled());
    expect(screen.getByText('Home and lists')).toBeTruthy();
    expect(screen.getByText('Conversations')).toBeTruthy();
    expect(screen.queryByText('Notifications')).toBeNull();
    expect(screen.getByText('Currently muted with no end time.')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));
    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { expires_in: null }));
  });

  it('removes an existing mute without creating another filter', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home'],
        filter_action: 'hide',
        expires_at: null,
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await waitFor(() => expect(screen.getByRole('button', { name: 'Unmute' })).not.toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: 'Unmute' }));

    await waitFor(() => expect(mockDelete).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9'));
    expect(mockPost).not.toHaveBeenCalled();
  });
});

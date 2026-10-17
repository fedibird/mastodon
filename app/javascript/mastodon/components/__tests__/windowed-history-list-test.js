import { List as ImmutableList } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { act, fireEvent, render } from '@testing-library/react';

const mockRestoreReadingAnchor = jest.fn(() => ({ ok: true }));
const mockCaptureReadingAnchor = jest.fn(() => ({ statusId: '80', displayRowId: '80', offsetPx: 4, alignment: 'top' }));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: message => message.defaultMessage }} />,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => () => null);
jest.mock('../reload_zone', () => () => null);

jest.mock('../../containers/status_container', () => {
  const ReactMock = require('react');

  return function StatusContainer (props) {
    return ReactMock.createElement('article', { 'data-id': props.id });
  };
});

jest.mock('../scrollable_list', () => {
  const ReactMock = require('react');

  return ReactMock.forwardRef(function ScrollableList (props, ref) {
    ReactMock.useImperativeHandle(ref, () => ({
      captureReadingAnchor: mockCaptureReadingAnchor,
      restoreReadingAnchor: mockRestoreReadingAnchor,
      node: {},
    }));

    const children = [props.children];

    if (props.onLoadNewer) {
      children.unshift(ReactMock.createElement('button', {
        type: 'button',
        'data-testid': 'newer',
        key: 'newer',
        onClick: props.onLoadNewer,
      }, 'newer'));
    }

    if (props.onLoadMore) {
      children.push(ReactMock.createElement('button', {
        type: 'button',
        'data-testid': 'older',
        key: 'older',
        onClick() {
          props.onLoadMore();
        },
      }, 'older'));
    }

    return ReactMock.createElement('div', null, children);
  });
});

import StatusList from '../status_list';

const store = () => createStore(state => state);

describe('StatusList windowed history', () => {
  beforeEach(() => {
    mockRestoreReadingAnchor.mockClear();
    mockCaptureReadingAnchor.mockClear();
  });

  it('pages from the raw anchor instead of the filtered tail and restores that row', () => {
    const onLoadMore = jest.fn();
    const onLoadNewer = jest.fn();
    const { getByTestId, rerender } = render(
      <Provider store={store()}>
        <StatusList
          scrollKey='history'
          trackScroll={false}
          windowedHistory
          hasMore
          hasNewer
          newerStatus='open'
          olderStatus='open'
          statusIds={ImmutableList(['100', '90'])}
          windowRevision={1}
          onLoadMore={onLoadMore}
          onLoadNewer={onLoadNewer}
        />
      </Provider>,
    );

    fireEvent.click(getByTestId('older'));

    expect(onLoadMore).toHaveBeenCalledWith(undefined, '80');
    expect(onLoadMore).not.toHaveBeenCalledWith('90');

    act(() => {
      rerender(
        <Provider store={store()}>
          <StatusList
            scrollKey='history'
            trackScroll={false}
            windowedHistory
            hasMore
            hasNewer
            newerStatus='open'
            olderStatus='open'
            statusIds={ImmutableList(['100', '90', '60'])}
            windowRevision={1}
            onLoadMore={onLoadMore}
            onLoadNewer={onLoadNewer}
          />
        </Provider>,
      );
    });

    expect(mockRestoreReadingAnchor).not.toHaveBeenCalled();

    act(() => {
      rerender(
        <Provider store={store()}>
          <StatusList
            scrollKey='history'
            trackScroll={false}
            windowedHistory
            hasMore
            hasNewer
            newerStatus='open'
            olderStatus='open'
            isLoading
            statusIds={ImmutableList(['100', '90', '70'])}
            windowRevision={2}
            onLoadMore={onLoadMore}
            onLoadNewer={onLoadNewer}
          />
        </Provider>,
      );
    });

    expect(mockRestoreReadingAnchor).toHaveBeenCalled();
    fireEvent.click(getByTestId('newer'));
    expect(onLoadNewer).not.toHaveBeenCalled();
  });
});

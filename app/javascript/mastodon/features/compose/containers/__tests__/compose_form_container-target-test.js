/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { combineReducers } from 'redux-immutable';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) return defaultMessage;
      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../../../components/autosuggest_textarea', () => {
  const React = require('react');

  return class AutosuggestTextarea extends React.Component {

    textarea = {
      setSelectionRange () {},
      focus () {},
      value: '',
    };

    render () {
      return (
        <textarea
          aria-label='Compose'
          autoFocus={this.props.autoFocus}
          data-autofocus={this.props.autoFocus ? 'true' : 'false'}
          value={this.props.value || ''}
          onChange={this.props.onChange}
        />
      );
    }

  };
});

jest.mock('../../../../components/autosuggest_input', () => {
  const React = require('react');

  return React.forwardRef((props, ref) => <input ref={ref} readOnly value={props.value || ''} />);
});
jest.mock('../reply_indicator_container', () => () => null);
jest.mock('../quote_indicator_container', () => () => null);
jest.mock('../poll_button_container', () => () => null);
jest.mock('../datetime_button_container', () => () => null);
jest.mock('../upload_button_container', () => () => null);
jest.mock('../spoiler_button_container', () => () => null);
jest.mock('../privacy_dropdown_container', () => () => null);
jest.mock('../searchability_dropdown_container', () => () => null);
jest.mock('../circle_dropdown_container', () => () => null);
jest.mock('../datetime_form_container', () => () => null);
jest.mock('../expires_indicator_container', () => () => null);
jest.mock('../emoji_picker_dropdown_container', () => () => null);
jest.mock('../language_dropdown_container', () => () => null);
jest.mock('../poll_form_container', () => () => null);
jest.mock('../upload_form_container', () => () => null);
jest.mock('../warning_container', () => () => null);
jest.mock('../../../../features/reference_stack', () => () => null);
jest.mock('../../../../is_mobile', () => ({ isMobile: () => false }));

import { changeCompose, changeComposeVisibility, setComposeToStatus } from '../../../../actions/compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../../../actions/composer';
import { groupPostingContext } from '../../../../posting_context/fixtures/group_context_fixture';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
import relationships from '../../../../reducers/relationships';
import { ComposerProvider } from '../../composer_id_context';
import ComposeFormContainer from '../compose_form_container';

const buildStore = () => {
  const store = createStore(combineReducers({
    compose,
    composers,
  }));

  store.dispatch(changeCompose('primary text'));
  store.dispatch(createComposer('composer-a'));
  store.dispatch(targetComposerAction(changeCompose('portable text'), 'composer-a'));

  return store;
};

describe('ComposeFormContainer composer targeting', () => {
  it('shows the primary draft when no composer provider is present', () => {
    render(
      <Provider store={buildStore()}>
        <ComposeFormContainer />
      </Provider>,
    );

    expect(screen.getByLabelText('Compose').value).toBe('primary text');
  });

  it('edits only the portable composer supplied by context', () => {
    const store = buildStore();

    render(
      <Provider store={store}>
        <ComposerProvider composerId='composer-a'>
          <ComposeFormContainer />
        </ComposerProvider>
      </Provider>,
    );

    const textarea = screen.getByLabelText('Compose');

    expect(textarea.value).toBe('portable text');

    fireEvent.change(textarea, { target: { value: 'changed portable' } });

    expect(store.getState().getIn(['compose', 'text'])).toEqual('primary text');
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'text'])).toEqual('changed portable');
  });

  it('keeps the default autoFocus when the prop is omitted', () => {
    render(
      <Provider store={buildStore()}>
        <ComposeFormContainer />
      </Provider>,
    );

    expect(screen.getByLabelText('Compose')).toHaveAttribute('data-autofocus', 'true');
  });

  it('does not pass autoFocus through connect when autoFocus is false', () => {
    render(
      <Provider store={buildStore()}>
        <ComposeFormContainer autoFocus={false} />
      </Provider>,
    );

    expect(screen.getByLabelText('Compose')).toHaveAttribute('data-autofocus', 'false');
  });

  it('enables publish when a live follow relationship becomes satisfied', () => {
    const store = createStore(combineReducers({ compose, composers, relationships }));
    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'composer-a'));
    store.dispatch(targetComposerAction(changeCompose('Hello'), 'composer-a'));
    store.dispatch(applyComposerPostingContext('composer-a', groupPostingContext));
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: false }],
    });

    render(
      <Provider store={store}>
        <ComposerProvider composerId='composer-a'>
          <ComposeFormContainer autoFocus={false} />
        </ComposerProvider>
      </Provider>,
    );

    expect(screen.getByLabelText('Compose').value).toBe('Hello');
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });

    expect(screen.getByLabelText('Compose').value).toBe('Hello');
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeEnabled();
  });

  it('keeps Save changes available while editing a private post without following the group', () => {
    const store = createStore(combineReducers({ compose, composers, relationships }));
    store.dispatch(createComposer('composer-a'));
    store.dispatch(applyComposerPostingContext('composer-a', groupPostingContext));
    store.dispatch(targetComposerAction(setComposeToStatus(fromJS({
      id: 'status-9',
      visibility: 'private',
      sensitive: false,
      media_attachments: [],
    }), 'Hello', ''), 'composer-a'));

    render(
      <Provider store={store}>
        <ComposerProvider composerId='composer-a'>
          <ComposeFormContainer autoFocus={false} />
        </ComposerProvider>
      </Provider>,
    );

    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'privacy'])).toEqual('private');
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
    expect(screen.getByLabelText('Compose').value).toBe('Hello');
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeEnabled();
  });
});

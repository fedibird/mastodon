/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import React from 'react';
import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import { Provider } from 'react-redux';
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

      return <textarea readOnly value={this.props.value || ''} />;

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
jest.mock('../poll_form_container', () => () => null);
jest.mock('../upload_form_container', () => () => null);
jest.mock('../warning_container', () => () => null);
jest.mock('../../../../features/reference_stack', () => () => null);
jest.mock('../../../../is_mobile', () => ({ isMobile: () => false }));

import ComposeFormContainer from '../compose_form_container';

const buildState = ({ id = null, privacy = 'public', circleId = null, prohibitedVisibilities = [], prohibitedWords = [], text = 'edited body' } = {}) => ImmutableMap({
  compose: ImmutableMap({
    text,
    suggestions: ImmutableList(),
    spoiler: false,
    spoiler_text: '',
    privacy,
    focusDate: null,
    caretPosition: null,
    preselectDate: null,
    is_submitting: false,
    is_changing_upload: false,
    is_uploading: false,
    circle_id: circleId,
    reply_status: null,
    media_attachments: ImmutableList(),
    prohibited_visibilities: ImmutableSet(prohibitedVisibilities),
    prohibited_words: ImmutableSet(prohibitedWords),
    scheduled: null,
    scheduled_status_id: null,
    id,
  }),
  search: ImmutableMap({
    submitted: false,
    hidden: true,
  }),
});

const renderForm = state => render(
  <Provider store={createStore(() => state)}>
    <ComposeFormContainer />
  </Provider>,
);

describe('ComposeFormContainer edit submit', () => {
  it('keeps Save available for a limited status opened from an empty compose', () => {
    renderForm(buildState({ id: 's1', privacy: 'limited', circleId: null }));

    expect(screen.getByRole('button', { name: 'Save changes' })).toBeEnabled();
  });

  it('keeps Save available when the immutable visibility is prohibited for new posts', () => {
    renderForm(buildState({
      id: 's1',
      privacy: 'direct',
      prohibitedVisibilities: ['direct'],
    }));

    expect(screen.getByRole('button', { name: 'Save changes' })).toBeEnabled();
  });

  it('still blocks a new limited post until a circle is selected', () => {
    renderForm(buildState({ id: null, privacy: 'limited', circleId: null, text: 'new post' }));

    expect(screen.getByRole('button', { name: 'Toot' })).toBeDisabled();
  });

  it('still blocks a new post whose visibility is prohibited', () => {
    renderForm(buildState({
      id: null,
      privacy: 'direct',
      prohibitedVisibilities: ['direct'],
      text: 'new post',
    }));

    expect(screen.getByRole('button', { name: 'Toot' })).toBeDisabled();
  });
});

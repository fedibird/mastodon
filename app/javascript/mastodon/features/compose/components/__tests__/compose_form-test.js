import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Set as ImmutableSet } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  disablePost: false,
  maxChars: 500,
}));

jest.mock('../../containers/reply_indicator_container', () => () => null);
jest.mock('../../containers/quote_indicator_container', () => () => null);
jest.mock('../../containers/poll_button_container', () => () => <div data-testid='poll-button' />);
jest.mock('../../containers/datetime_button_container', () => () => null);
jest.mock('../../containers/upload_button_container', () => () => <div data-testid='upload-button' />);
jest.mock('../../containers/spoiler_button_container', () => () => null);
jest.mock('../../containers/privacy_dropdown_container', () => {
  const PropTypes = require('prop-types');

  const PrivacyDropdownContainerMock = ({ showLabel, disabled }) => (
    <div
      data-testid='privacy-dropdown'
      data-show-label={showLabel ? 'true' : 'false'}
      data-disabled={disabled ? 'true' : 'false'}
    />
  );

  PrivacyDropdownContainerMock.propTypes = {
    showLabel: PropTypes.bool,
    disabled: PropTypes.bool,
  };

  return PrivacyDropdownContainerMock;
});
jest.mock('../../containers/searchability_dropdown_container', () => () => null);
jest.mock('../../containers/circle_dropdown_container', () => () => null);
jest.mock('../../containers/datetime_form_container', () => () => null);
jest.mock('../../containers/expires_indicator_container', () => () => null);
jest.mock('../../containers/emoji_picker_dropdown_container', () => () => null);
jest.mock('../../containers/language_dropdown_container', () => () => <div data-testid='language-dropdown' />);
jest.mock('../../containers/poll_form_container', () => () => null);
jest.mock('../../containers/upload_form_container', () => () => null);
jest.mock('../../containers/warning_container', () => () => null);
jest.mock('../../../reference_stack', () => () => null);

import ComposeForm from '../compose_form';

const noop = () => {};

const renderForm = (props = {}) => render(
  <ComposeForm
    text=''
    suggestions={ImmutableList()}
    privacy='public'
    prohibitedVisibilities={ImmutableSet()}
    prohibitedWords={ImmutableSet()}
    onChange={noop}
    onSubmit={noop}
    onClearSuggestions={noop}
    onFetchSuggestions={noop}
    onSuggestionSelected={noop}
    onChangeSpoilerText={noop}
    onPaste={noop}
    onPickEmoji={noop}
    {...props}
  />,
);

describe('ComposeForm autoFocus', () => {
  it('focuses the textarea when autoFocus is omitted', () => {
    renderForm();

    expect(screen.getByPlaceholderText('What is on your mind?')).toHaveFocus();
  });

  it('does not focus the textarea when autoFocus is false', () => {
    renderForm({ autoFocus: false });

    expect(screen.getByPlaceholderText('What is on your mind?')).not.toHaveFocus();
  });
});

describe('ComposeForm visibility controls', () => {
  it('places privacy and language above the textarea and leaves publish in place', () => {
    renderForm();

    const form = document.querySelector('.compose-form');
    const spoiler = form.querySelector(':scope > .spoiler-input');
    const dropdowns = form.querySelector(':scope > .compose-form__dropdowns');
    const autosuggest = form.querySelector(':scope > .compose-form__autosuggest-wrapper');
    const buttons = document.querySelector('.compose-form__buttons');
    const publish = document.querySelector('.compose-form__publish');
    const privacy = screen.getByTestId('privacy-dropdown');
    const language = screen.getByTestId('language-dropdown');

    expect(spoiler.compareDocumentPosition(dropdowns) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(dropdowns.compareDocumentPosition(autosuggest) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(dropdowns).toContainElement(privacy);
    expect(dropdowns).toContainElement(language);
    expect(dropdowns.children[0]).toBe(privacy);
    expect(dropdowns.children[1]).toBe(language);
    expect(privacy).toHaveAttribute('data-show-label', 'true');
    expect(privacy).toHaveAttribute('data-disabled', 'false');
    expect(buttons).not.toContainElement(privacy);
    expect(buttons).not.toContainElement(language);
    expect(buttons).toContainElement(screen.getByTestId('upload-button'));
    expect(buttons).toContainElement(screen.getByTestId('poll-button'));
    expect(publish).toContainElement(screen.getByRole('button', { name: 'Toot!' }));
  });
});

import { fireEvent, render, screen } from '@testing-library/react';
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
jest.mock('../../containers/spoiler_button_container', () => () => <div data-testid='spoiler-button' />);
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
jest.mock('../../containers/circle_dropdown_container', () => () => <div data-testid='circle-dropdown' />);
jest.mock('../../containers/datetime_form_container', () => () => null);
jest.mock('../../containers/expires_indicator_container', () => () => null);
jest.mock('../../containers/emoji_picker_dropdown_container', () => () => <div data-testid='emoji-picker' />);
jest.mock('../../containers/language_dropdown_container', () => () => <div data-testid='language-dropdown' />);
jest.mock('../../containers/poll_form_container', () => () => <div data-testid='poll-form' />);
jest.mock('../../containers/upload_form_container', () => () => <div data-testid='upload-form' />);
jest.mock('../../containers/warning_container', () => () => null);
jest.mock('../../containers/posting_context_bar_container', () => () => <div data-testid='posting-context-bar' />);
jest.mock('../../../reference_stack', () => () => <div data-testid='reference-stack' />);

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

describe('ComposeForm posting context visibility', () => {
  it('shows the posting context bar for a new post', () => {
    renderForm();

    expect(screen.getByTestId('posting-context-bar')).toBeTruthy();
  });

  it('hides the posting context bar while editing a status', () => {
    renderForm({ isEditing: true });

    expect(screen.queryByTestId('posting-context-bar')).toBeNull();
  });

  it('hides the posting context bar while editing a scheduled status', () => {
    renderForm({ isScheduledStatusEditting: true });

    expect(screen.queryByTestId('posting-context-bar')).toBeNull();
  });
});

describe('ComposeForm effective text', () => {
  it('keeps the textarea on the raw draft and counts effective text', () => {
    renderForm({ text: 'hi', effectiveText: 'hi\n\n#foo' });

    expect(screen.getByPlaceholderText('What is on your mind?')).toHaveValue('hi');
    expect(screen.getByText('492')).toBeTruthy();
  });

  it('disables publish when the materialized text exceeds the limit or contains a prohibited word', () => {
    const { unmount } = renderForm({ text: 'hello', effectiveText: 'h'.repeat(501) });

    expect(screen.getByPlaceholderText('What is on your mind?')).toHaveValue('hello');
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    unmount();

    renderForm({
      text: 'hello',
      effectiveText: 'hello\n\n#spam',
      prohibitedWords: ImmutableSet(['#spam']),
    });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
  });

  it('disables publish when the posting context is not compliant', () => {
    renderForm({ text: 'Hello', contextCompliant: false });

    expect(screen.getByPlaceholderText('What is on your mind?')).toHaveValue('Hello');
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
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
    const wrapper = document.querySelector('.compose-form__buttons-wrapper');
    const submit = document.querySelector('.compose-form__submit');
    const publish = screen.getByRole('button', { name: 'Toot!' });
    const privacy = screen.getByTestId('privacy-dropdown');
    const language = screen.getByTestId('language-dropdown');
    const circle = screen.getByTestId('circle-dropdown');

    expect(spoiler.compareDocumentPosition(dropdowns) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    const postingContext = screen.getByTestId('posting-context-bar');

    expect(dropdowns.compareDocumentPosition(postingContext) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(postingContext.compareDocumentPosition(autosuggest) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
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
    expect(document.querySelector('.compose-form__publish')).toBeNull();
    expect(autosuggest.compareDocumentPosition(circle) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(circle.compareDocumentPosition(wrapper) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(wrapper).toContainElement(submit);
    expect(submit).toContainElement(screen.getByText('500'));
    expect(submit).toContainElement(publish);
    expect(publish).not.toHaveClass('button--block');
  });
});

const advancedControls = [
  'privacy-dropdown',
  'language-dropdown',
  'upload-button',
  'poll-button',
  'spoiler-button',
  'emoji-picker',
  'circle-dropdown',
  'posting-context-bar',
  'reference-stack',
  'upload-form',
  'poll-form',
];

describe('ComposeForm display mode', () => {
  it('stays on the full composer when no mode callback is provided', () => {
    renderForm({ displayMode: 'simple' });

    expect(document.querySelector('.compose-form--simple')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Switch to simple view' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Show full composer' })).toBeNull();
    expect(screen.getByPlaceholderText('What is on your mind?')).toBeTruthy();
    expect(document.querySelector('.character-counter')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    advancedControls.forEach(id => {
      expect(screen.getByTestId(id)).toBeTruthy();
    });
  });

  it('offers simple view from a full portable composer', () => {
    const onDisplayModeChange = jest.fn();

    renderForm({ displayMode: 'full', onDisplayModeChange });

    fireEvent.click(screen.getByRole('button', { name: 'Switch to simple view' }));

    expect(onDisplayModeChange).toHaveBeenCalledWith('simple');
    expect(document.querySelector('.character-counter')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    advancedControls.forEach(id => {
      expect(screen.getByTestId(id)).toBeTruthy();
    });
  });

  it('mounts only the textarea, full-view button, and publish button in simple mode', () => {
    renderForm({ displayMode: 'simple', onDisplayModeChange: jest.fn() });

    expect(screen.getAllByRole('textbox')).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: 'Show full composer' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: 'Toot!' })).toHaveLength(1);
    expect(screen.getAllByRole('button')).toHaveLength(2);
    expect(document.querySelectorAll('.character-counter')).toHaveLength(0);
    advancedControls.forEach(id => {
      expect(screen.queryByTestId(id)).toBeNull();
    });
  });

  it('keeps the textarea node and caret when switching modes', () => {
    const onDisplayModeChange = jest.fn();
    const view = renderForm({ text: 'hello caret', displayMode: 'full', onDisplayModeChange });
    const textarea = screen.getByPlaceholderText('What is on your mind?');

    textarea.setSelectionRange(3, 3);
    view.rerender(
      <ComposeForm
        text='hello caret'
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
        displayMode='simple'
        onDisplayModeChange={onDisplayModeChange}
      />,
    );

    const simpleTextarea = screen.getByPlaceholderText('What is on your mind?');

    expect(simpleTextarea).toBe(textarea);
    expect(simpleTextarea.selectionStart).toBe(3);
    expect(simpleTextarea).toHaveValue('hello caret');

    view.rerender(
      <ComposeForm
        text='hello caret'
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
        displayMode='full'
        onDisplayModeChange={onDisplayModeChange}
      />,
    );

    expect(screen.getByPlaceholderText('What is on your mind?')).toBe(textarea);
    expect(textarea.selectionStart).toBe(3);
  });

  it('submits from the button and the keyboard in full and simple mode', () => {
    const onSubmit = jest.fn();
    const shared = {
      text: 'hello',
      onSubmit,
      onDisplayModeChange: jest.fn(),
    };
    const full = renderForm({ ...shared, displayMode: 'full' });

    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    fireEvent.keyDown(screen.getByPlaceholderText('What is on your mind?'), { keyCode: 13, ctrlKey: true });
    expect(onSubmit).toHaveBeenCalledTimes(2);
    full.unmount();

    onSubmit.mockClear();
    renderForm({ ...shared, displayMode: 'simple' });
    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    fireEvent.keyDown(screen.getByPlaceholderText('What is on your mind?'), { keyCode: 13, metaKey: true });
    expect(onSubmit).toHaveBeenCalledTimes(2);
  });

  it('keeps the simple composer send guard for a public-only destination', () => {
    const onSubmit = jest.fn();

    renderForm({
      text: 'hello',
      privacy: 'unlisted',
      displayMode: 'simple',
      canAttempt: false,
      capabilityReason: 'compliance',
      onSubmit,
      onDisplayModeChange: jest.fn(),
    });

    expect(screen.getByRole('button', { name: 'Toot' })).toBeDisabled();
    expect(screen.getByRole('status').textContent).toContain('Posting conditions are not met');
    fireEvent.click(screen.getByRole('button', { name: 'Toot' }));
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('shows a simple-mode send guard without hiding the reason', () => {
    const onSubmit = jest.fn();
    const onDisplayModeChange = jest.fn();

    renderForm({
      text: 'hello',
      displayMode: 'simple',
      canAttempt: false,
      capabilityReason: 'compliance',
      onSubmit,
      onDisplayModeChange,
    });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    expect(screen.getByRole('status').textContent).toContain('Posting conditions are not met');
    expect(screen.queryByText('Create permission not confirmed · compatibility method')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    expect(onSubmit).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Show details' }));
    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
  });

  it('disables publish in both modes when the post cannot be submitted', () => {
    const full = renderForm({
      text: 'hello',
      contextCompliant: false,
      displayMode: 'full',
      onDisplayModeChange: jest.fn(),
    });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    full.unmount();

    renderForm({
      text: 'hello',
      contextCompliant: false,
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
    });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
  });

  it('uses the private publish label in both modes', () => {
    const full = renderForm({
      text: 'hello',
      privacy: 'private',
      displayMode: 'full',
      onDisplayModeChange: jest.fn(),
    });

    expect(document.querySelector('.compose-form__publish-private')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot' })).toBeEnabled();
    full.unmount();

    renderForm({
      text: 'hello',
      privacy: 'private',
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
    });

    expect(document.querySelector('.compose-form__publish-private')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot' })).toBeEnabled();
  });

  it('returns to full view before accepting a pasted file', () => {
    const order = [];
    const onDisplayModeChange = jest.fn(() => {
      order.push('mode');
    });
    const onPaste = jest.fn(() => {
      order.push('paste');
    });
    const file = new File(['x'], 'photo.png', { type: 'image/png' });
    const view = renderForm({
      text: 'hello',
      displayMode: 'simple',
      onDisplayModeChange,
      onPaste,
    });

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind?'), {
      clipboardData: { files: [file] },
    });

    expect(order).toEqual(['mode', 'paste']);
    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
    expect(screen.queryByTestId('upload-form')).toBeNull();

    view.rerender(
      <ComposeForm
        text='hello'
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
        onPaste={onPaste}
        onPickEmoji={noop}
        displayMode='full'
        onDisplayModeChange={onDisplayModeChange}
      />,
    );

    expect(screen.getByTestId('upload-form')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Show full composer' })).toBeNull();
  });

  it('leaves a text paste on the simple composer', () => {
    const onDisplayModeChange = jest.fn();
    const onPaste = jest.fn();

    renderForm({
      text: 'hello',
      displayMode: 'simple',
      onDisplayModeChange,
      onPaste,
    });

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind?'), {
      clipboardData: { files: [] },
    });

    expect(onDisplayModeChange).not.toHaveBeenCalled();
    expect(onPaste).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Show full composer' })).toBeTruthy();
  });
});

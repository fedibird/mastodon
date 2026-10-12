import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
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
jest.mock('../../containers/searchability_dropdown_container', () => () => <div data-testid='searchability-dropdown' />);
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
import SenderIdentity from '../sender_identity';

const noop = () => {};

const SimpleStyleButton = ({ onSelect }) => (
  <button type='button' onClick={onSelect}>読書メモ</button>
);

SimpleStyleButton.propTypes = {
  onSelect: () => null,
};

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
  it('keeps the posting context out of the textarea and in the header selector', () => {
    renderForm({ stylePicker: <div data-testid='posting-context-bar'>Group</div> });

    const header = document.querySelector('.compose-form__header');
    const textarea = screen.getByPlaceholderText('What is on your mind?');

    expect(header).toContainElement(screen.getByTestId('posting-context-bar'));
    expect(textarea.compareDocumentPosition(screen.getByTestId('posting-context-bar')) & Node.DOCUMENT_POSITION_PRECEDING).toBeTruthy();
    expect(document.querySelector('.compose-form__modifiers')).not.toContainElement(screen.getByTestId('posting-context-bar'));
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
  it('places privacy and language in the one-line header and the counter beside the text', () => {
    renderForm({ spoiler: true, spoilerText: 'cw' });

    const header = document.querySelector('.compose-form__header');
    const spoiler = document.querySelector('[data-testid="cw-input"]');
    const autosuggest = document.querySelector('.compose-form__autosuggest-wrapper');
    const buttons = document.querySelector('.compose-form__buttons');
    const submit = document.querySelector('.compose-form__submit');
    const publish = screen.getByRole('button', { name: 'Toot!' });
    const privacy = screen.getByTestId('privacy-dropdown');
    const language = screen.getByTestId('language-dropdown');
    const counter = screen.getByTestId('character-count');

    expect(header).toContainElement(privacy);
    expect(header).not.toContainElement(language);
    expect(header.children.length).toBeGreaterThan(0);
    expect(getComputedStyle(header).flexWrap || 'nowrap').not.toBe('wrap');
    expect(privacy).toHaveAttribute('data-show-label', 'true');
    expect(privacy).toHaveAttribute('data-disabled', 'false');
    expect(buttons).not.toContainElement(privacy);
    expect(buttons).toContainElement(language);
    expect(buttons).not.toContainElement(screen.getByTestId('emoji-picker'));
    expect(buttons).toContainElement(screen.getByTestId('upload-button'));
    expect(buttons).toContainElement(screen.getByTestId('spoiler-button'));
    expect(document.querySelector('.compose-form__emoji-anchor')).toContainElement(screen.getByTestId('emoji-picker'));
    expect(counter).toContainElement(screen.getByText('498'));
    expect(submit).not.toContainElement(counter);
    expect(submit.querySelector('.character-counter')).toBeNull();
    expect(header.compareDocumentPosition(spoiler) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(spoiler.compareDocumentPosition(autosuggest) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(submit).toContainElement(publish);
    expect(document.querySelector('[data-composer-preflight]')).toBeTruthy();
    expect(publish).not.toHaveClass('button--block');
  });

  it('hides the content warning field until it is turned on', () => {
    const view = renderForm();

    expect(screen.queryByTestId('cw-input')).toBeNull();

    view.rerender(
      <ComposeForm
        text=''
        suggestions={ImmutableList()}
        privacy='public'
        spoiler
        spoilerText='careful'
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
      />,
    );

    const spoiler = screen.getByTestId('cw-input');
    const autosuggest = document.querySelector('.compose-form__autosuggest-wrapper');

    expect(spoiler.querySelector('input, textarea')).toHaveValue('careful');
    expect(spoiler.compareDocumentPosition(autosuggest) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });
});

const advancedControls = [
  'upload-button',
  'spoiler-button',
  'emoji-picker',
  'circle-dropdown',
  'reference-stack',
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

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    fireEvent.click(screen.getByRole('button', { name: 'Switch to simple view' }));

    expect(onDisplayModeChange).toHaveBeenCalledWith('simple');
    expect(document.querySelector('.character-counter')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    advancedControls.forEach(id => {
      expect(screen.getByTestId(id)).toBeTruthy();
    });
  });

  it('keeps attach, content warning, language, and a labeled publish button in simple mode', () => {
    renderForm({ displayMode: 'simple', onDisplayModeChange: jest.fn() });

    const buttons = document.querySelector('.compose-form__buttons');

    expect(document.querySelector('.compose-form__header')).toBeTruthy();
    expect(screen.getByTestId('privacy-dropdown')).toBeTruthy();
    expect(document.querySelector('.compose-form__header')).not.toContainElement(screen.getByTestId('language-dropdown'));
    expect(buttons).toContainElement(screen.getByTestId('language-dropdown'));
    expect(buttons).toContainElement(screen.getByTestId('upload-button'));
    expect(buttons).toContainElement(screen.getByTestId('spoiler-button'));
    expect(screen.getByTestId('upload-form')).toBeTruthy();
    expect(screen.getAllByRole('textbox')).toHaveLength(1);
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    expect(document.querySelector('.compose-form__publish-icon')).toBeNull();
    expect(document.querySelectorAll('.character-counter')).toHaveLength(0);
    expect(document.querySelector('.compose-form__buttons-wrapper')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const mode = screen.getByRole('button', { name: 'Show full composer' });

    expect(mode).toHaveTextContent('Show full composer');
    expect(mode.querySelector('.fa-expand')).toBeTruthy();
    ['emoji-picker', 'circle-dropdown', 'reference-stack', 'poll-form'].forEach(id => {
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

  it('changes a posting style in simple mode without leaving simple mode', () => {
    const onDisplayModeChange = jest.fn();
    const onSelect = jest.fn();

    renderForm({
      displayMode: 'simple',
      onDisplayModeChange,
      privacy: 'unlisted',
      stylePicker: <SimpleStyleButton onSelect={onSelect} />,
    });

    expect(screen.getByTestId('privacy-dropdown')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '読書メモ' }));

    expect(onSelect).toHaveBeenCalled();
    expect(onDisplayModeChange).not.toHaveBeenCalled();
    expect(document.querySelector('.compose-form--simple')).toBeTruthy();
  });

  it('explains a blocked destination change in simple mode', () => {
    const onSubmit = jest.fn();
    const onAcceptSurface = jest.fn();

    renderForm({
      text: 'hello',
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      surfaceMismatch: true,
      onAcceptSurface,
      onSubmit,
    });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    expect(screen.getByRole('status').textContent).toContain('previous destination');

    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    fireEvent.click(screen.getByRole('button', { name: 'Use this destination' }));

    expect(onSubmit).not.toHaveBeenCalled();
    expect(onAcceptSurface).toHaveBeenCalledTimes(1);
  });

  it('attaches a pasted file without leaving simple mode', () => {
    const onDisplayModeChange = jest.fn();
    const onPaste = jest.fn();
    const file = new File(['x'], 'photo.png', { type: 'image/png' });

    renderForm({
      text: 'hello',
      displayMode: 'simple',
      onDisplayModeChange,
      onPaste,
      composerId: 'portable:hashtag:1',
    });

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind?'), {
      clipboardData: { files: [file] },
    });

    expect(onDisplayModeChange).not.toHaveBeenCalled();
    expect(onPaste).toHaveBeenCalledWith(expect.any(Object));
    expect(document.querySelector('.compose-form--simple')).toBeTruthy();
    expect(document.querySelector('[data-composer-id="portable:hashtag:1"]')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    expect(screen.getByRole('button', { name: 'Show full composer' })).toBeTruthy();
  });

  it('keeps a dropped file on the composer under the pointer', () => {
    const onPaste = jest.fn();
    const other = jest.fn();
    const file = new File(['x'], 'photo.png', { type: 'image/png' });

    renderForm({
      text: 'hello',
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      onPaste,
      composerId: 'portable:list:9',
    });

    fireEvent.drop(document.querySelector('[data-composer-id="portable:list:9"]'), {
      dataTransfer: { types: ['Files'], files: [file] },
    });

    expect(onPaste).toHaveBeenCalled();
    expect(other).not.toHaveBeenCalled();
    expect(document.querySelector('.compose-form--simple')).toBeTruthy();
  });

  it('names the upload block and clears it when attaching is allowed again', () => {
    const onPaste = jest.fn();
    const file = new File(['x'], 'photo.png', { type: 'image/png' });
    const view = renderForm({
      text: 'hello',
      canUploadMedia: false,
      uploadBlockReason: 'poll',
      onPaste,
    });

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind?'), {
      clipboardData: { files: [file] },
    });

    expect(onPaste).not.toHaveBeenCalled();
    expect(screen.getByRole('status').textContent).toContain('Remove the poll');

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
        canUploadMedia
        uploadBlockReason={null}
      />,
    );

    expect(screen.queryByText(/Remove the poll/)).toBeNull();
  });

  it('opens full editing after a simple composer gains a poll, schedule, or content warning', () => {
    const onDisplayModeChange = jest.fn();
    const view = renderForm({ displayMode: 'simple', onDisplayModeChange });

    view.rerender(
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
        displayMode='simple'
        onDisplayModeChange={onDisplayModeChange}
        hasPoll
      />,
    );

    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
    onDisplayModeChange.mockClear();

    view.rerender(
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
        displayMode='simple'
        onDisplayModeChange={onDisplayModeChange}
        datetimeOpen
      />,
    );

    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
    onDisplayModeChange.mockClear();

    view.rerender(
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
        displayMode='simple'
        onDisplayModeChange={onDisplayModeChange}
        spoiler
      />,
    );

    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
    onDisplayModeChange.mockClear();

    view.rerender(
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
        displayMode='simple'
        onDisplayModeChange={onDisplayModeChange}
        overflowContext={<div data-testid='posting-context'>Required mention</div>}
      />,
    );

    expect(onDisplayModeChange).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const menu = screen.getByTestId('composer-overflow-menu');

    expect(document.querySelector('.compose-form__header')).not.toContainElement(screen.getByTestId('posting-context'));
    expect(menu).toContainElement(screen.getByTestId('posting-context'));
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
  });

  it('opens schedule actions in an overlay outside the button row', () => {
    renderForm();

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const menu = screen.getByTestId('composer-overflow-menu');
    const buttons = document.querySelector('.compose-form__buttons');
    const header = document.querySelector('.compose-form__header');

    expect(menu).toBeTruthy();
    expect(buttons).not.toContainElement(menu);
    expect(header).not.toContainElement(screen.getByTestId('searchability-dropdown'));
    expect(header).not.toContainElement(screen.getByTestId('poll-button'));
    expect(menu).toContainElement(screen.getByTestId('searchability-dropdown'));
    expect(menu).toContainElement(screen.getByTestId('poll-button'));
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
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
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    expect(screen.getByRole('button', { name: 'Show full composer' })).toBeTruthy();
  });
});

const senderIdentity = (compact = false) => (
  <SenderIdentity
    compact={compact}
    current={ImmutableMap({
      id: 'local:42',
      authorization: 'ready',
      account: ImmutableMap({ acct: 'admin', displayName: 'Admin' }),
    })}
    selectedId='local:42'
  />
);

describe('ComposeForm sender identity', () => {
  it('shows the sender separately from the posting style and the destination', () => {
    renderForm({
      senderIdentity: senderIdentity(),
      stylePicker: <div data-testid='style-picker'>読書メモ</div>,
    });

    const header = document.querySelector('.compose-form__header');
    const identity = screen.getByTestId('sender-identity');
    const style = screen.getByTestId('style-picker');

    expect(header).not.toContainElement(identity);
    expect(document.querySelector('.compose-form__buttons')).toContainElement(identity);
    expect(header).toContainElement(style);
    expect(identity.textContent).toContain('Posting as');
    expect(identity.textContent).toContain('@admin');
    expect(style.compareDocumentPosition(identity) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(style).not.toContainElement(identity);
  });

  it('shows who is posting in simple mode', () => {
    renderForm({
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      senderIdentity: senderIdentity(true),
    });

    const header = document.querySelector('.compose-form__header');
    const sender = screen.getByTestId('sender-identity');

    expect(header).not.toContainElement(sender);
    expect(document.querySelector('.compose-form__buttons')).toContainElement(sender);
    expect(sender.className).toContain('compose-form__sender--compact');
    expect(sender.textContent).toContain('Posting as');
    expect(sender.textContent).toContain('@admin');
    expect(sender.textContent).not.toContain('does not change the account you are logged in as');
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeEnabled();
  });

  it('disables publish when the sender identity cannot post', () => {
    const onSubmit = jest.fn();

    renderForm({ text: 'hello', canSendAsIdentity: false, onSubmit });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    expect(onSubmit).not.toHaveBeenCalled();
  });
});

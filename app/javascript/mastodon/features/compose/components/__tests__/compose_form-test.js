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
jest.mock('../../containers/searchability_dropdown_container', () => {
  const React = require('react');
  const PropTypes = require('prop-types');

  const SearchabilityDropdownContainer = ({ open, presentation }) => (
    <div
      data-testid='searchability-dropdown'
      data-open={open ? 'true' : 'false'}
      data-presentation={presentation || ''}
    />
  );

  SearchabilityDropdownContainer.propTypes = {
    open: PropTypes.bool,
    presentation: PropTypes.string,
  };

  return SearchabilityDropdownContainer;
});
jest.mock('../../containers/circle_dropdown_container', () => () => <div data-testid='circle-dropdown' />);
jest.mock('../../containers/datetime_form_container', () => () => null);
jest.mock('../../containers/expires_indicator_container', () => () => <div data-testid='expires-indicator' />);
jest.mock('../../containers/searchability_indicator_container', () => () => <div data-testid='searchability-indicator' />);
jest.mock('../../containers/emoji_picker_dropdown_container', () => () => <div data-testid='emoji-picker' />);
jest.mock('../../containers/language_dropdown_container', () => () => <div data-testid='language-dropdown' />);
jest.mock('../../containers/poll_form_container', () => () => <div data-testid='poll-form' />);
jest.mock('../../containers/upload_form_container', () => {
  const MockUploadForm = ({ endAccessory }) => (
    <div data-testid='upload-form'>{endAccessory}</div>
  );

  MockUploadForm.propTypes = {
    endAccessory: () => null,
  };

  return MockUploadForm;
});
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

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveFocus();
  });

  it('does not focus the textarea when autoFocus is false', () => {
    renderForm({ autoFocus: false });

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).not.toHaveFocus();
  });
});

describe('ComposeForm posting context visibility', () => {
  it('keeps the posting context out of the textarea and in the header selector', () => {
    renderForm({ stylePicker: <div data-testid='posting-context-bar'>Group</div> });

    const header = document.querySelector('.compose-form__header');
    const textarea = screen.getByPlaceholderText('What is on your mind? (Auto-detect)');

    expect(header).toContainElement(screen.getByTestId('posting-context-bar'));
    expect(textarea.compareDocumentPosition(screen.getByTestId('posting-context-bar')) & Node.DOCUMENT_POSITION_PRECEDING).toBeTruthy();
    expect(document.querySelector('.compose-form__modifiers')).not.toContainElement(screen.getByTestId('posting-context-bar'));
  });
});

describe('ComposeForm effective text', () => {
  it('keeps the textarea on the raw draft and counts effective text', () => {
    renderForm({ text: 'hi', effectiveText: 'hi\n\n#foo' });

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveValue('hi');
    expect(screen.getByText('492')).toBeTruthy();
  });

  it('disables publish when the materialized text exceeds the limit or contains a prohibited word', () => {
    const { unmount } = renderForm({ text: 'hello', effectiveText: 'h'.repeat(501) });

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveValue('hello');
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

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveValue('Hello');
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
    expect(document.querySelector('.autosuggest-textarea')).not.toContainElement(counter);
    expect(screen.getByTestId('upload-form')).toContainElement(counter);
    expect(document.querySelector('.compose-form__end')).not.toContainElement(counter);
    expect(counter.compareDocumentPosition(screen.getByTestId('poll-form')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByTestId('poll-form').compareDocumentPosition(screen.getByTestId('searchability-indicator')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(counter.compareDocumentPosition(publish) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(document.querySelectorAll('[data-testid="character-count"]')).toHaveLength(1);
    expect(submit).not.toContainElement(counter);
    expect(submit.querySelector('.character-counter')).toBeNull();
    expect(header.compareDocumentPosition(spoiler) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(spoiler.compareDocumentPosition(autosuggest) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(submit).toContainElement(publish);
    expect(document.querySelector('[data-composer-preflight]')).toBeTruthy();
    expect(publish).not.toHaveClass('button--block');
  });

  it('places the character count on the sensitive row when media is attached', () => {
    renderForm({ anyMedia: true, text: 'hi' });

    const upload = screen.getByTestId('upload-form');
    const counter = screen.getByTestId('character-count');

    expect(upload).toContainElement(counter);
    expect(document.querySelector('.compose-form__end')).not.toContainElement(counter);
    expect(document.querySelector('.compose-form__submit')).not.toContainElement(counter);
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
    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toBeTruthy();
    expect(document.querySelector('.character-counter')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    advancedControls.forEach(id => {
      expect(screen.getByTestId(id)).toBeTruthy();
    });
  });

  it('offers simple view from a full portable composer', () => {
    const onDisplayModeChange = jest.fn();

    renderForm({ displayMode: 'full', onDisplayModeChange });

    const toggle = screen.getByRole('button', { name: 'Switch to simple view' });

    expect(document.querySelector('.compose-form__header')).toContainElement(toggle);
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    expect(screen.getByTestId('composer-overflow-menu')).not.toContainElement(toggle);
    fireEvent.click(toggle);

    expect(onDisplayModeChange).toHaveBeenCalledWith('simple');
    expect(document.querySelector('.character-counter')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeTruthy();
    advancedControls.forEach(id => {
      expect(screen.getByTestId(id)).toBeTruthy();
    });
  });

  it('gives a portable composer four rows when full and two rows when compact', () => {
    const full = renderForm({ displayMode: 'full', onDisplayModeChange: jest.fn() });

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveAttribute('data-text-rows', '4');
    expect(screen.queryByRole('button', { name: 'Show full composer' })).toBeNull();
    full.unmount();

    const onDisplayModeChange = jest.fn();

    renderForm({ displayMode: 'simple', onDisplayModeChange });

    const textarea = screen.getByPlaceholderText('What is on your mind? (Auto-detect)');
    const expand = screen.getByRole('button', { name: 'Show full composer' });

    expect(textarea).toHaveAttribute('data-text-rows', '2');
    expect(document.querySelector('.compose-form__header')).toContainElement(expand);
    fireEvent.click(expand);
    expect(onDisplayModeChange).toHaveBeenCalledWith('full');
  });

  it('keeps the primary composer on the autosizing textarea', () => {
    renderForm();

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).not.toHaveAttribute('data-text-rows');
  });

  it('shows the upload area as soon as a compact upload starts', () => {
    const view = renderForm({ displayMode: 'simple', onDisplayModeChange: jest.fn(), text: 'hello' });
    const before = screen.getByRole('button', { name: 'Toot!' });

    expect(document.querySelector('.compose-form__compact-publish')).toContainElement(before);
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
        onPaste={noop}
        onPickEmoji={noop}
        displayMode='simple'
        onDisplayModeChange={jest.fn()}
        isUploading
        pendingMedia={1}
      />,
    );

    const publish = screen.getByRole('button', { name: 'Toot!' });

    expect(screen.getByTestId('upload-form')).toBeTruthy();
    expect(document.querySelector('.compose-form__simple-row')).toContainElement(publish);
    expect(document.querySelector('.compose-form__compact-publish')).toBeNull();
    expect(publish).toBeDisabled();
    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveValue('hello');
  });

  it('keeps a compact composer to the header, text, and icon publish button', () => {
    renderForm({ displayMode: 'simple', onDisplayModeChange: jest.fn() });

    const header = document.querySelector('.compose-form__header');
    const publish = screen.getByRole('button', { name: 'Toot!' });

    expect(header).toBeTruthy();
    expect(header).toContainElement(screen.getByTestId('privacy-dropdown'));
    expect(screen.queryByTestId('language-dropdown')).toBeNull();
    expect(screen.queryByTestId('upload-button')).toBeNull();
    expect(screen.queryByTestId('spoiler-button')).toBeNull();
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(screen.queryByTestId('upload-form')).toBeNull();
    expect(screen.getAllByRole('textbox')).toHaveLength(1);
    expect(publish).toHaveClass('compose-form__publish-icon');
    expect(document.querySelector('.compose-form__compact-publish')).toContainElement(publish);
    expect(document.querySelectorAll('.character-counter')).toHaveLength(0);
    expect(document.querySelector('.compose-form__buttons-wrapper')).toBeNull();
    ['emoji-picker', 'circle-dropdown', 'reference-stack', 'poll-form'].forEach(id => {
      expect(screen.queryByTestId(id)).toBeNull();
    });
  });

  it('places the icon publish button beside compact thumbnails', () => {
    renderForm({ displayMode: 'simple', onDisplayModeChange: jest.fn(), anyMedia: true });

    const publish = screen.getByRole('button', { name: 'Toot!' });

    expect(screen.getByTestId('upload-form')).toBeTruthy();
    expect(document.querySelector('.compose-form__compact-publish')).toBeNull();
    expect(document.querySelector('.compose-form__simple-row')).toContainElement(publish);
    expect(screen.queryByTestId('upload-button')).toBeNull();
  });

  it('keeps the textarea node and caret when switching modes', () => {
    const onDisplayModeChange = jest.fn();
    const view = renderForm({ text: 'hello caret', displayMode: 'full', onDisplayModeChange });
    const textarea = screen.getByPlaceholderText('What is on your mind? (Auto-detect)');

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

    const simpleTextarea = screen.getByPlaceholderText('What is on your mind? (Auto-detect)');

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

    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toBe(textarea);
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
    fireEvent.keyDown(screen.getByPlaceholderText('What is on your mind? (Auto-detect)'), { keyCode: 13, ctrlKey: true });
    expect(onSubmit).toHaveBeenCalledTimes(2);
    full.unmount();

    onSubmit.mockClear();
    renderForm({ ...shared, displayMode: 'simple' });
    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    fireEvent.keyDown(screen.getByPlaceholderText('What is on your mind? (Auto-detect)'), { keyCode: 13, metaKey: true });
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

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind? (Auto-detect)'), {
      clipboardData: { files: [file] },
    });

    expect(onDisplayModeChange).not.toHaveBeenCalled();
    expect(onPaste).toHaveBeenCalledWith(expect.any(Object));
    expect(document.querySelector('.compose-form--simple')).toBeTruthy();
    expect(document.querySelector('[data-composer-id="portable:hashtag:1"]')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(screen.queryByTestId('upload-button')).toBeNull();
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

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind? (Auto-detect)'), {
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
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(screen.queryByTestId('posting-context')).toBeNull();

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
        displayMode='full'
        onDisplayModeChange={onDisplayModeChange}
        overflowContext={<div data-testid='posting-context'>Required mention</div>}
      />,
    );

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
    expect(menu).not.toContainElement(screen.getByTestId('searchability-dropdown'));
    expect(menu).toContainElement(screen.getByRole('button', { name: 'Search visibility' }));
    expect(screen.getByRole('button', { name: 'Search visibility' }).querySelector('.fa-search')).toBeTruthy();
    expect(menu).toContainElement(screen.getByTestId('poll-button'));

    fireEvent.click(screen.getByRole('button', { name: 'Search visibility' }));

    expect(screen.queryByTestId('composer-overflow-menu')).toBeNull();
    expect(screen.getByTestId('searchability-dropdown')).toHaveAttribute('data-open', 'true');
    expect(screen.getByTestId('searchability-dropdown')).toHaveAttribute('data-presentation', 'detached');
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

    fireEvent.paste(screen.getByPlaceholderText('What is on your mind? (Auto-detect)'), {
      clipboardData: { files: [] },
    });

    expect(onDisplayModeChange).not.toHaveBeenCalled();
    expect(onPaste).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
  });

  it('shows a compact search badge for an explicitly narrower search range', () => {
    renderForm({
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      privacy: 'private',
      searchability: 'direct',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    });

    const badge = screen.getByRole('button', { name: 'Reacted-users-only' });

    expect(badge).toHaveClass('compose-form__simple-badge');
    expect(badge.querySelector('.fa-search')).toBeTruthy();
    expect(document.querySelector('.compose-form--searchability-note')).toBeTruthy();
  });

  it('hides the search badge after the widened privacy is restored', () => {
    const restored = {
      privacy: 'direct',
      searchability: 'direct',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    };
    const simple = renderForm({
      ...restored,
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
    });

    expect(screen.queryByRole('button', { name: 'Followers-only' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Reacted-users-only' })).toBeNull();
    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
    simple.unmount();

    renderForm(restored);

    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
  });

  it('does not mark a reply or quote that only follows the privacy cap', () => {
    const capped = {
      privacy: 'direct',
      searchability: 'direct',
      defaultSearchability: 'private',
    };
    const full = renderForm(capped);

    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
    full.unmount();

    renderForm({
      ...capped,
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
    });

    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Reacted-users-only' })).toBeNull();
    expect(document.querySelector('.compose-form__simple-badge')).toBeNull();
  });

  it('does not keep a search badge after a style drops the restore point', () => {
    const settled = {
      privacy: 'unlisted',
      searchability: 'private',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    };
    const full = renderForm(settled);

    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
    full.unmount();

    renderForm({
      ...settled,
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
    });

    expect(screen.queryByRole('button', { name: 'Followers-only' })).toBeNull();
    expect(document.querySelector('.compose-form--searchability-note')).toBeNull();
  });

  it('keeps a full search note and a compact badge on separate composers', () => {
    renderForm({
      composerId: 'primary',
      privacy: 'private',
      searchability: 'direct',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    });
    renderForm({
      composerId: 'portable:1',
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      privacy: 'direct',
      searchability: 'direct',
      defaultSearchability: 'private',
    });

    const forms = document.querySelectorAll('.compose-form');

    expect(forms[0]).toHaveClass('compose-form--searchability-note');
    expect(forms[0]).toHaveAttribute('data-composer-id', 'primary');
    expect(forms[1]).not.toHaveClass('compose-form--searchability-note');
    expect(forms[1]).toHaveAttribute('data-composer-id', 'portable:1');
    expect(forms[1].querySelector('.compose-form__simple-badge')).toBeNull();
  });

  it('keeps a changed search visibility off the character count', () => {
    renderForm({
      text: 'hello',
      searchability: 'public',
      defaultSearchability: 'private',
    });

    const anchor = document.querySelector('.compose-form__count-anchor');

    expect(screen.queryByTestId('searchability-label')).toBeNull();
    expect(anchor.querySelector('.compose-form__searchability-label')).toBeNull();
    expect(anchor.querySelector('.character-counter')).toBeTruthy();
    expect(document.querySelectorAll('[data-testid="character-count"]')).toHaveLength(1);
  });

  it('follows the posting language in the placeholder without rewriting the draft', () => {
    const view = renderForm({ text: 'hello caret', lang: 'ja' });
    const textarea = screen.getByPlaceholderText('今なにしてる？ (Japanese)');

    textarea.setSelectionRange(2, 2);

    view.rerender(
      <ComposeForm
        text='hello caret'
        lang='en'
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
      />,
    );

    const next = screen.getByPlaceholderText('What\'s on your mind? (English)');

    expect(next).toBe(textarea);
    expect(next).toHaveValue('hello caret');
    expect(next.selectionStart).toBe(2);
    expect(next).toHaveAttribute('lang', 'en');
    expect(textarea).not.toHaveAttribute('aria-live');
  });

  it('turns off only the content warning from its close button', () => {
    const onToggleSpoilerness = jest.fn();

    renderForm({ spoiler: true, spoilerText: 'cw', text: 'hello', onToggleSpoilerness });

    fireEvent.click(screen.getByRole('button', { name: 'Remove content warning' }));

    expect(onToggleSpoilerness).toHaveBeenCalledTimes(1);
    expect(screen.getByPlaceholderText('What is on your mind? (Auto-detect)')).toHaveValue('hello');
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

  it('hides the posting account in simple mode', () => {
    renderForm({
      displayMode: 'simple',
      onDisplayModeChange: jest.fn(),
      senderIdentity: senderIdentity(true),
    });

    expect(screen.queryByTestId('sender-identity')).toBeNull();
    expect(document.querySelector('.compose-form__header')).toContainElement(screen.getByTestId('privacy-dropdown'));
    expect(screen.getByRole('button', { name: 'Toot!' })).toBeEnabled();
  });

  it('offers discard instead of retry when redraft media is unconfirmed', () => {
    const onRetryRedraft = jest.fn();
    const onDiscardUnconfirmedRedraft = jest.fn();
    const view = renderForm({
      text: 'held',
      redraftNotice: 'unconfirmed',
      onRetryRedraft,
      onDiscardUnconfirmedRedraft,
    });

    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
    expect(screen.getByText('The images from the original post could not be confirmed, so this draft cannot be posted.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Discard this draft' }));
    expect(onDiscardUnconfirmedRedraft).toHaveBeenCalledTimes(1);
    expect(onRetryRedraft).not.toHaveBeenCalled();

    view.unmount();
    renderForm({
      text: 'held',
      displayMode: 'simple',
      redraftNotice: 'unconfirmed',
      onRetryRedraft,
      onDiscardUnconfirmedRedraft,
    });

    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Discard this draft' })).toBeTruthy();
  });

  it('still offers retry when a redraft attachment failed and can be tried again', () => {
    const onRetryRedraft = jest.fn();

    renderForm({
      text: 'held',
      redraftNotice: 'prepare',
      onRetryRedraft,
      onDiscardUnconfirmedRedraft: jest.fn(),
    });

    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(onRetryRedraft).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('button', { name: 'Discard this draft' })).toBeNull();
  });

  it('disables publish when the sender identity cannot post', () => {
    const onSubmit = jest.fn();

    renderForm({ text: 'hello', canSendAsIdentity: false, onSubmit });

    expect(screen.getByRole('button', { name: 'Toot!' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Toot!' }));
    expect(onSubmit).not.toHaveBeenCalled();
  });
});

const controlOrder = () => Array.from(document.querySelectorAll('.compose-form__buttons [data-composer-control]')).map(node => node.getAttribute('data-composer-control'));

describe('ComposeForm composer toolbar', () => {
  it('uses the saved default order and keeps more actions last', () => {
    renderForm({ senderIdentity: senderIdentity() });

    expect(controlOrder()).toEqual(['posting_account', 'media', 'cw', 'language', 'overflow']);
    expect(document.querySelector('.compose-form__buttons')).toContainElement(screen.getByTestId('sender-identity'));
    expect(document.querySelector('.compose-form__submit')).toContainElement(screen.getByRole('button', { name: 'Toot!' }));
    expect(screen.queryByRole('button', { name: 'Publish and expiry time' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const menu = screen.getByTestId('composer-overflow-menu');

    expect(menu).toContainElement(screen.getByRole('button', { name: 'Search visibility' }));
    expect(menu).toContainElement(screen.getByTestId('poll-button'));
    expect(controlOrder()[controlOrder().length - 1]).toEqual('overflow');
  });

  it('shows every control in the footer and omits more actions when none are in the menu', () => {
    renderForm({
      composerToolbar: [
        { id: 'poll', placement: 'visible' },
        { id: 'datetime', placement: 'visible' },
        { id: 'searchability', placement: 'visible' },
        { id: 'language', placement: 'visible' },
        { id: 'cw', placement: 'visible' },
        { id: 'media', placement: 'visible' },
        { id: 'posting_account', placement: 'visible' },
      ],
    });

    expect(controlOrder()).toEqual(['poll', 'datetime', 'searchability', 'language', 'cw', 'media', 'posting_account']);
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(document.querySelector('.compose-form__buttons')).toContainElement(screen.getByTestId('poll-button'));
    expect(document.querySelector('.compose-form__buttons')).toContainElement(screen.getByTestId('searchability-dropdown'));
    expect(screen.getByTestId('searchability-dropdown')).toHaveAttribute('data-presentation', '');
  });

  it('hides every control and still opens non-custom overflow content', () => {
    renderForm({
      composerToolbar: [
        'posting_account', 'media', 'cw', 'language', 'datetime', 'searchability', 'poll',
      ].map(id => ({ id, placement: 'hidden' })),
      overflowContext: <div data-testid='posting-context'>Required mention</div>,
    });

    expect(controlOrder()).toEqual(['overflow']);
    expect(screen.queryByTestId('upload-button')).toBeNull();
    expect(screen.queryByTestId('poll-button')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const menu = screen.getByTestId('composer-overflow-menu');

    expect(menu).toContainElement(screen.getByTestId('posting-context'));
    expect(menu).not.toContainElement(screen.queryByRole('button', { name: 'Search visibility' }));
  });

  it('moves the old footer actions into the menu and the old menu actions into the footer', () => {
    renderForm({
      showPostingAccount: true,
      senderIdentity: senderIdentity(),
      composerToolbar: [
        { id: 'datetime', placement: 'visible' },
        { id: 'searchability', placement: 'visible' },
        { id: 'poll', placement: 'visible' },
        { id: 'posting_account', placement: 'menu' },
        { id: 'media', placement: 'menu' },
        { id: 'cw', placement: 'menu' },
        { id: 'language', placement: 'menu' },
      ],
    });

    expect(controlOrder().slice(0, 3)).toEqual(['datetime', 'searchability', 'poll']);
    expect(screen.queryByTestId('upload-button')).toBeNull();
    expect(screen.queryByTestId('sender-identity')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));

    const menu = screen.getByTestId('composer-overflow-menu');

    expect(menu).toContainElement(screen.getByRole('button', { name: 'Posting as' }));
    expect(menu).toContainElement(screen.getByTestId('upload-button'));
    expect(menu).toContainElement(screen.getByTestId('spoiler-button'));
    expect(menu).toContainElement(screen.getByRole('button', { name: 'Change language' }));
    expect(controlOrder()[controlOrder().length - 1]).toEqual('overflow');

    fireEvent.click(screen.getByRole('button', { name: 'Change language' }));

    expect(screen.queryByTestId('composer-overflow-menu')).toBeNull();
    expect(screen.getByTestId('language-dropdown')).toBeTruthy();
  });

  it('keeps editable menu actions while editing and drops schedule actions', () => {
    renderForm({
      isEditing: true,
      overflowContext: <div data-testid='posting-context'>Required mention</div>,
      composerToolbar: [
        { id: 'posting_account', placement: 'hidden' },
        { id: 'media', placement: 'visible' },
        { id: 'cw', placement: 'menu' },
        { id: 'language', placement: 'hidden' },
        { id: 'datetime', placement: 'menu' },
        { id: 'searchability', placement: 'visible' },
        { id: 'poll', placement: 'menu' },
      ],
    });

    expect(screen.queryByTestId('poll-button')).toBeNull();
    expect(screen.queryByTestId('searchability-dropdown')).toBeNull();
    expect(screen.queryByTestId('posting-context')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    expect(screen.getByTestId('composer-overflow-menu')).toContainElement(screen.getByTestId('spoiler-button'));
    expect(screen.queryByRole('button', { name: 'Search visibility' })).toBeNull();
  });

  it('drops a hidden posting account without rendering it', () => {
    renderForm({
      senderIdentity: senderIdentity(),
      composerToolbar: [
        { id: 'posting_account', placement: 'hidden' },
        { id: 'media', placement: 'visible' },
        { id: 'cw', placement: 'visible' },
        { id: 'language', placement: 'visible' },
        { id: 'datetime', placement: 'menu' },
        { id: 'searchability', placement: 'menu' },
        { id: 'poll', placement: 'menu' },
      ],
    });

    expect(screen.queryByTestId('sender-identity')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Posting as' })).toBeNull();
  });
});

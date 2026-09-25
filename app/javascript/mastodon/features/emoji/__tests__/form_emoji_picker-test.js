/* eslint-disable react/prop-types, react/jsx-no-bind */

import { fireEvent, screen, waitFor } from '@testing-library/react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: () => 'Insert emoji' };

  return {
    addLocaleData: () => {},
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    IntlProvider: ({ children }) => children,
  };
});

jest.mock('mastodon/locales', () => ({
  getLocale: () => ({ localeData: [], messages: {} }),
}));

let mockPickerId = 0;
jest.mock('mastodon/features/compose/components/emoji_picker_dropdown', () => {
  const React = require('react');

  return ({ button, onOpen, onClose, onPickEmoji, openDropdownId }) => {
    const [id] = React.useState(() => `picker-${mockPickerId++}`);
    const open = openDropdownId === id;

    return (
      <div>
        {React.cloneElement(button, { onClick: () => open ? onClose(id) : onOpen(id) })}
        {open && (
          <div>
            <button type='button' onClick={() => onPickEmoji({ native: ':fedibird:' })}>Custom emoji</button>
            <button type='button' onClick={() => onPickEmoji({ native: '😀' })}>Unicode emoji</button>
          </div>
        )}
      </div>
    );
  };
});

import {
  initializeFormEmojiPickers,
  insertEmojiAtSelection,
  resetCustomEmojiPromiseForTests,
} from '../form_emoji_picker';

const emojiResponse = [{
  shortcode: 'fedibird',
  url: 'https://example.test/fedibird.gif',
  static_url: 'https://example.test/fedibird.png',
  visible_in_picker: true,
  category: 'Fedibird',
  aliases: [],
}];

describe('form emoji picker', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
    mockPickerId = 0;
    resetCustomEmojiPromiseForTests();
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(emojiResponse),
    }));
  });

  it('decorates only opted-in fields once and fetches custom emoji once', async () => {
    document.body.innerHTML = `
      <input id="first" type="text" data-emoji-picker="true">
      <input id="plain" type="text">
      <textarea id="note" data-emoji-picker="true"></textarea>
    `;

    initializeFormEmojiPickers();
    initializeFormEmojiPickers();

    expect(document.querySelectorAll('.emoji-picker-input')).toHaveLength(2);
    expect(document.querySelectorAll('.emoji-picker-input__button-host')).toHaveLength(2);
    expect(document.querySelector('.emoji-picker-input__button-host').tagName).toBe('DIV');
    expect(document.querySelector('#plain').parentElement).not.toHaveClass('emoji-picker-input');
    expect(document.querySelector('#note').parentElement).toHaveClass('emoji-picker-input--textarea');
    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
  });

  it('shares open state and inserts custom and Unicode emoji at the saved selection', async () => {
    document.body.innerHTML = `
      <input id="first" type="text" data-emoji-picker="true" value="abcdefghi">
      <input id="second" type="text" data-emoji-picker="true" value="two">
    `;
    const first = document.querySelector('#first');
    const second = document.querySelector('#second');
    const inputListener = jest.fn();
    first.addEventListener('input', inputListener);

    initializeFormEmojiPickers();

    first.focus();
    first.setSelectionRange(3, 6);
    fireEvent.select(first);
    const pickerButtons = screen.getAllByRole('button', { name: 'Insert emoji' });
    fireEvent.mouseDown(pickerButtons[0]);
    fireEvent.click(pickerButtons[0]);
    expect(screen.getByRole('button', { name: 'Custom emoji' })).toBeInTheDocument();

    second.focus();
    second.setSelectionRange(3, 3);
    fireEvent.select(second);
    fireEvent.mouseDown(pickerButtons[1]);
    fireEvent.click(pickerButtons[1]);
    expect(screen.getAllByRole('button', { name: 'Custom emoji' })).toHaveLength(1);
    fireEvent.click(screen.getByRole('button', { name: 'Unicode emoji' }));
    expect(second.value).toBe('two😀');

    fireEvent.click(pickerButtons[0]);
    fireEvent.click(screen.getByRole('button', { name: 'Custom emoji' }));
    expect(first.value).toBe('abc:fedibird:ghi');
    expect(first.selectionStart).toBe(13);
    expect(first.selectionEnd).toBe(13);
    expect(document.activeElement).toBe(first);
    expect(inputListener).toHaveBeenCalledTimes(1);
  });

  it('does not insert a value that would exceed maxlength', () => {
    const field = document.createElement('input');
    field.maxLength = 5;
    field.value = 'abcde';

    expect(insertEmojiAtSelection(field, '😀', { start: 5, end: 5 })).toBe(false);
    expect(field.value).toBe('abcde');
  });

  it('keeps fields usable when the custom emoji request fails', async () => {
    global.fetch = jest.fn(() => Promise.reject(new Error('offline')));
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true">';

    initializeFormEmojiPickers();
    const field = document.querySelector('#field');
    field.value = 'still editable';
    fireEvent.input(field);

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
    expect(field.value).toBe('still editable');
    expect(screen.getByRole('button', { name: 'Insert emoji' })).toBeInTheDocument();
  });

  it('safely emojifies marked text and leaves unknown shortcodes literal', async () => {
    document.body.innerHTML = '<span data-custom-emoji-text>Work :fedibird: :missing: &lt;script&gt;alert(1)&lt;/script&gt;</span>';

    initializeFormEmojiPickers();

    await waitFor(() => expect(document.querySelector('img.custom-emoji')).not.toBeNull());
    const marker = document.querySelector('[data-custom-emoji-text]');
    expect(marker).toHaveTextContent('Work :missing: <script>alert(1)</script>');
    expect(marker.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:');
    expect(marker.querySelector('script')).toBeNull();
  });
});

/* eslint-disable react/prop-types, react/jsx-no-bind */

import ReactDOM from 'react-dom';
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

    expect(document.querySelectorAll('.emoji-picker-field')).toHaveLength(2);
    expect(document.querySelectorAll('.emoji-picker-input')).toHaveLength(2);
    expect(document.querySelectorAll('.emoji-picker-preview')).toHaveLength(2);
    expect(document.querySelectorAll('.emoji-picker-input__button-host')).toHaveLength(2);
    expect(document.querySelector('.emoji-picker-input__button-host').tagName).toBe('DIV');
    expect(document.querySelector('#first').parentElement).toHaveClass('emoji-picker-input');
    expect(document.querySelector('#first').parentElement.parentElement).toHaveClass('emoji-picker-field');
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

    const secondPreview = second.parentElement.parentElement.querySelector('.emoji-picker-preview');
    expect(secondPreview.querySelector('img.emojione')).toHaveAttribute('alt', '😀');
    expect(second.value).toBe('two😀');

    await waitFor(() => {
      const firstPreview = first.parentElement.parentElement.querySelector('.emoji-picker-preview');
      expect(firstPreview.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:');
    });
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

  it('previews adjacent custom emoji and leaves the canonical shortcodes in the field', async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve([
        ...emojiResponse,
        {
          shortcode: 'foo',
          url: 'https://example.test/foo.gif',
          static_url: 'https://example.test/foo.png',
          visible_in_picker: true,
          category: 'Fedibird',
          aliases: [],
        },
        {
          shortcode: 'bar',
          url: 'https://example.test/bar.gif',
          static_url: 'https://example.test/bar.png',
          visible_in_picker: true,
          category: 'Fedibird',
          aliases: [],
        },
      ]),
    }));
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value=":foo::bar:">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(preview.querySelectorAll('img.custom-emoji')).toHaveLength(2));
    expect(preview.querySelectorAll('img.custom-emoji')[0]).toHaveAttribute('data-shortcode', 'foo');
    expect(preview.querySelectorAll('img.custom-emoji')[1]).toHaveAttribute('data-shortcode', 'bar');
    expect(field.value).toBe(':foo::bar:');
    expect(field.value).not.toContain('\u200B');
  });

  it('previews a shortcode beside ASCII text and keeps the field canonical', async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve([
        ...emojiResponse,
        {
          shortcode: 'foo',
          url: 'https://example.test/foo.gif',
          static_url: 'https://example.test/foo.png',
          visible_in_picker: true,
          category: 'Fedibird',
          aliases: [],
        },
      ]),
    }));
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="abc:foo:def">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(preview).toHaveTextContent('abcdef');
    expect(preview.textContent).not.toContain('\u200B');
    expect(field.value).toBe('abc:foo:def');
    expect(field.value).not.toContain('\u200B');
  });

  it('previews a shortcode beside Japanese text and keeps the field canonical', async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve([
        ...emojiResponse,
        {
          shortcode: 'foo',
          url: 'https://example.test/foo.gif',
          static_url: 'https://example.test/foo.png',
          visible_in_picker: true,
          category: 'Fedibird',
          aliases: [],
        },
      ]),
    }));
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="日本語:foo:です">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(preview).toHaveTextContent('日本語です');
    expect(preview.textContent).not.toContain('\u200B');
    expect(field.value).toBe('日本語:foo:です');
    expect(field.value).not.toContain('\u200B');
  });

  it('previews custom emoji below the plain-text field and updates on input', async () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="Work :fedibird:">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');
    expect(preview).not.toBeNull();
    expect(field.value).toBe('Work :fedibird:');

    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:'));
    expect(preview).toHaveTextContent('Work');
    expect(field.value).toBe('Work :fedibird:');
  });

  it('updates the preview when the field value changes', async () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="Hello">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');
    expect(preview).toHaveTextContent('Hello');

    field.value = 'Hello :fedibird:';
    fireEvent.input(field);

    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:'));
    expect(preview).toHaveTextContent('Hello');
    expect(field.value).toBe('Hello :fedibird:');
  });

  it('escapes html in the preview and still renders the custom emoji', async () => {
    const field = document.createElement('input');
    field.type = 'text';
    field.dataset.emojiPicker = 'true';
    field.value = '<script>alert(1)</script> :fedibird:';
    document.body.appendChild(field);

    initializeFormEmojiPickers();

    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:'));
    expect(preview.querySelector('script')).toBeNull();
    expect(preview).toHaveTextContent('<script>alert(1)</script>');
    expect(field.value).toBe('<script>alert(1)</script> :fedibird:');
  });

  it('does not show preview content for an empty field', () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const fieldWrap = field.parentElement.parentElement;
    const preview = fieldWrap.querySelector('.emoji-picker-preview');
    expect(fieldWrap).not.toHaveClass('emoji-picker-field--has-preview');
    expect(preview).toBeEmptyDOMElement();
    expect(preview.textContent).toBe('');
  });

  it('marks the wrapper when the field starts with a previewable value', async () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="Hello :fedibird:">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const fieldWrap = field.parentElement.parentElement;
    const preview = fieldWrap.querySelector('.emoji-picker-preview');

    expect(field.parentElement).toHaveClass('emoji-picker-input');
    expect(field.parentElement.nextElementSibling).toBe(preview);
    expect(fieldWrap).toHaveClass('emoji-picker-field--has-preview');
    await waitFor(() => expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:'));
    expect(preview).not.toBeEmptyDOMElement();
  });

  it('toggles the attached preview class when the field gains and loses text', () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const fieldWrap = field.parentElement.parentElement;
    const preview = fieldWrap.querySelector('.emoji-picker-preview');

    field.value = 'Hello';
    fireEvent.input(field);

    expect(fieldWrap).toHaveClass('emoji-picker-field--has-preview');
    expect(preview).toHaveTextContent('Hello');

    field.value = '';
    fireEvent.input(field);

    expect(fieldWrap).not.toHaveClass('emoji-picker-field--has-preview');
    expect(preview).toBeEmptyDOMElement();
  });

  it('keeps a whitespace-only value as preview content', () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value=" ">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const fieldWrap = field.parentElement.parentElement;

    expect(field.value).toBe(' ');
    expect(fieldWrap).toHaveClass('emoji-picker-field--has-preview');
    expect(fieldWrap.querySelector('.emoji-picker-preview')).not.toBeEmptyDOMElement();
  });

  it('removes the input listener when the picker unmounts', () => {
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="Hello">';
    const field = document.querySelector('#field');
    const removeEventListener = jest.spyOn(field, 'removeEventListener');
    const root = initializeFormEmojiPickers();

    ReactDOM.unmountComponentAtNode(root);

    expect(removeEventListener).toHaveBeenCalledWith('input', expect.any(Function));
  });

  it('keeps shortcodes literal in the preview when custom emoji loading fails', async () => {
    global.fetch = jest.fn(() => Promise.reject(new Error('offline')));
    document.body.innerHTML = '<input id="field" type="text" data-emoji-picker="true" value="Hello 😀 :fedibird:">';

    initializeFormEmojiPickers();

    const field = document.querySelector('#field');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
    expect(field.value).toBe('Hello 😀 :fedibird:');
    expect(preview.querySelector('img.custom-emoji')).toBeNull();
    expect(preview.querySelector('img.emojione')).toHaveAttribute('alt', '😀');
    expect(preview).toHaveTextContent(':fedibird:');
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

  const fooEmojiResponse = () => ([
    ...emojiResponse,
    {
      shortcode: 'foo',
      url: 'https://example.test/foo.gif',
      static_url: 'https://example.test/foo.png',
      visible_in_picker: true,
      category: 'Fedibird',
      aliases: [],
    },
  ]);

  const mountDisplayNameCard = (value) => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(fooEmojiResponse()),
    }));
    document.body.innerHTML = `
      <input id="account_display_name" type="text" data-emoji-picker="true" data-default="alice" value="${value}">
      <div class="card"><div class="display-name"><bdi><strong class="emojify p-name">saved name</strong></bdi></div></div>
    `;
    initializeFormEmojiPickers();

    return {
      field: document.querySelector('#account_display_name'),
      name: document.querySelector('.card .display-name strong'),
    };
  };

  it('renders a custom emoji in the profile card display name and keeps the field canonical', async () => {
    const { field, name } = mountDisplayNameCard(':foo:開発用');
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');

    await waitFor(() => expect(name.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(name.textContent).toBe('開発用');
    expect(name.textContent).not.toContain(':foo:');
    expect(name.textContent).not.toContain('\u200B');
    expect(preview.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo');
    expect(preview).toHaveTextContent('開発用');
    expect(field.value).toBe(':foo:開発用');
    expect(field.value).not.toContain('\u200B');
  });

  it('renders an ASCII-adjacent shortcode in the profile card display name', async () => {
    const { field, name } = mountDisplayNameCard('abc:foo:def');

    await waitFor(() => expect(name.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(name.textContent).toBe('abcdef');
    expect(name.textContent).not.toContain(':foo:');
    expect(field.value).toBe('abc:foo:def');
    expect(field.value).not.toContain('\u200B');
  });

  it('renders a Japanese-adjacent shortcode in the profile card display name', async () => {
    const { field, name } = mountDisplayNameCard('日本語:foo:です');

    await waitFor(() => expect(name.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(name.textContent).toBe('日本語です');
    expect(field.value).toBe('日本語:foo:です');
    expect(field.value).not.toContain('\u200B');
  });

  it('escapes html in the profile card display name and still renders the custom emoji', async () => {
    const { field, name } = mountDisplayNameCard('');
    field.value = '<script>alert(1)</script>:foo:';
    fireEvent.input(field);

    await waitFor(() => expect(name.querySelector('img.custom-emoji')).toHaveAttribute('data-shortcode', 'foo'));
    expect(name.querySelector('script')).toBeNull();
    expect(name.textContent).toContain('<script>alert(1)</script>');
    expect(field.value).toBe('<script>alert(1)</script>:foo:');
    expect(field.value).not.toContain('\u200B');
  });

  it('updates the profile card display name as the field changes', async () => {
    const { field, name } = mountDisplayNameCard('Hello');

    await waitFor(() => expect(name.textContent).toBe('Hello'));
    field.value = 'abc:foo:def';
    fireEvent.input(field);

    await waitFor(() => expect(name.textContent).toBe('abcdef'));
    expect(name.querySelectorAll('img.custom-emoji')).toHaveLength(1);
    expect(field.value).toBe('abc:foo:def');
    expect(field.value).not.toContain('\u200B');
  });
});

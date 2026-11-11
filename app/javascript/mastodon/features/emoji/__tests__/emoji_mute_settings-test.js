import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import EmojiMuteSettings, { DEFAULT_REPLACEMENT } from '../emoji_mute_settings';

jest.mock('../emoji_picker_shell', () => () => null);

const native = '🧪';
const secretUrl = 'https://cdn.example/muted-secret.png';

const documentResponse = {
  revision: '4',
  effect_application: {
    applied: ['reject_reactions_to_own_posts', 'hide_reactions', 'replace_in_text'],
    stored_only: ['hide_in_picker'],
  },
  emoji_mutes: [
    {
      id: '15',
      revision: '3',
      emoji: { kind: 'unicode', native, url: secretUrl },
      effects: {
        replace_in_text: true,
        reject_reactions_to_own_posts: true,
        hide_reactions: true,
        hide_in_picker: true,
      },
      replacement: DEFAULT_REPLACEMENT,
      detail: { state: 'resolved', kind: 'unicode', emoji_id: 'test_tube' },
    },
    {
      id: '16',
      revision: '1',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '44', shortcode: 'secret_shortcode', url: secretUrl },
      effects: {
        replace_in_text: true,
        reject_reactions_to_own_posts: false,
        hide_reactions: true,
        hide_in_picker: false,
      },
      replacement: '',
      detail: { state: 'unavailable', kind: 'custom', scope: 'local', custom_emoji_id: '44', shortcode: 'secret_shortcode' },
    },
  ],
};

function renderSettings(props) {
  return render(
    <IntlProvider locale='en' messages={{}}>
      <EmojiMuteSettings {...props} />
    </IntlProvider>,
  );
}

describe('Emoji mute settings', () => {
  const setItem = jest.spyOn(Storage.prototype, 'setItem');

  beforeEach(() => {
    setItem.mockClear();
  });

  it('shows replacements immediately and resolves originals only after the display toggle', async () => {
    const resolveEmoji = jest.fn(reference => Promise.resolve(reference.kind === 'unicode' ? {
      detail: { native, image: { src: '/emoji/test-tube.svg', alt: native } },
    } : {
      detail: {
        state: 'fetched',
        kind: 'custom',
        emoji: {
          shortcode: 'secret_shortcode',
          url: '/emoji/secret.gif',
          static_url: '/emoji/secret.png',
        },
      },
    }));
    const view = renderSettings({
      loadDocument: () => Promise.resolve(documentResponse),
      resolveEmoji,
    });

    expect(screen.getByText('Loading muted emoji…')).toBeTruthy();
    expect(await screen.findByText(DEFAULT_REPLACEMENT)).toBeTruthy();
    expect(screen.getByText('(empty)')).toBeTruthy();
    expect(resolveEmoji).not.toHaveBeenCalled();
    expect(view.container.innerHTML).not.toContain(secretUrl);

    fireEvent.click(screen.getByRole('checkbox', { name: 'Display original emoji' }));

    await waitFor(() => expect(resolveEmoji).toHaveBeenCalledTimes(2));
    expect((await screen.findAllByText(native)).length).toBeGreaterThan(0);
    const images = Array.from(view.container.querySelectorAll('img')).map(image => image.getAttribute('src'));
    expect(images).toContain('/emoji/secret.gif');
    expect(view.container.innerHTML).not.toContain(secretUrl);
    expect(setItem).not.toHaveBeenCalled();
  });

  it('selects rows and applies replacement and effect changes in bulk', async () => {
    const saveRule = jest.fn();

    let currentDocument = documentResponse;
    const loadDocument = jest.fn(() => Promise.resolve(currentDocument));

    saveRule.mockImplementation((id, revision, effects, replacement) => {
      const updated = {
        ...documentResponse.emoji_mutes.find(rule => rule.id === id),
        revision: String(Number(revision) + 1),
        effects,
        replacement,
      };

      currentDocument = {
        ...currentDocument,
        revision: String(Number(currentDocument.revision) + 1),
        emoji_mutes: currentDocument.emoji_mutes.map(rule => rule.id === id ? updated : rule),
      };

      return Promise.resolve({
        revision: currentDocument.revision,
        emoji_mute: updated,
      });
    });

    renderSettings({
      loadDocument,
      saveRule,
    });

    await screen.findByText(DEFAULT_REPLACEMENT);
    fireEvent.click(screen.getByRole('button', { name: 'Select all shown' }));
    expect(screen.getByText('2 selected')).toBeTruthy();

    fireEvent.click(screen.getByText('Change replacement text'));
    const bulkReplacement = screen.getByRole('textbox', { name: 'Set replacement for selected' });
    fireEvent.change(bulkReplacement, { target: { value: '□' } });

    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'off' } });
    fireEvent.change(selects[1], { target: { value: 'off' } });
    fireEvent.change(selects[2], { target: { value: 'off' } });
    fireEvent.change(selects[3], { target: { value: 'off' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply to selected' }));

    await waitFor(() => expect(saveRule).toHaveBeenCalledTimes(2));
    saveRule.mock.calls.forEach(call => {
      expect(call[3]).toBe('□');
      expect(call[2]).toEqual({
        replace_in_text: false,
        reject_reactions_to_own_posts: false,
        hide_reactions: false,
        hide_in_picker: false,
      });
    });
    expect(await screen.findByText('Bulk changes applied.')).toBeTruthy();

    const rowCheckboxes = screen.getAllByRole('checkbox').filter(input => input.hasAttribute('data-effect'));
    expect(rowCheckboxes.every(input => input.checked === false)).toBe(true);
  });

  it('supports compact emoji-only selection mode and bulk removal', async () => {
    const removeRule = jest.fn(() => Promise.resolve({ revision: '7' }));

    renderSettings({
      loadDocument: () => Promise.resolve(documentResponse),
      removeRule,
    });

    await screen.findByText(DEFAULT_REPLACEMENT);
    fireEvent.click(screen.getByRole('tab', { name: 'Select emoji' }));

    const options = screen.getAllByRole('option');
    fireEvent.click(options[0]);
    expect(options[0].getAttribute('aria-selected')).toBe('true');
    expect(screen.getByText('1 selected')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Remove selected mutes' }));
    await waitFor(() => expect(removeRule).toHaveBeenCalledWith('15', '3'));
    await waitFor(() => expect(screen.getAllByRole('option')).toHaveLength(1));
  });

  it('keeps an edited row when an individual save conflicts', async () => {
    const saveRule = jest.fn().mockRejectedValue(Object.assign(new Error('conflict'), { status: 409, code: 'conflict' }));

    renderSettings({
      loadDocument: () => Promise.resolve(documentResponse),
      saveRule,
    });

    await screen.findByText(DEFAULT_REPLACEMENT);
    const replacementInputs = screen.getAllByDisplayValue(DEFAULT_REPLACEMENT);
    fireEvent.change(replacementInputs[0], { target: { value: 'kept' } });
    fireEvent.click(screen.getAllByRole('button', { name: 'Save changes' })[0]);

    await waitFor(() => expect(saveRule).toHaveBeenCalledWith('15', '3', expect.any(Object), 'kept'));
    expect(screen.getByDisplayValue('kept')).toBeTruthy();
    expect(await screen.findByText('This mute changed elsewhere. Reload the page and try again.')).toBeTruthy();
  });
});

/**
 * @jest-environment jsdom
 */

import React from 'react';
import { render, fireEvent, waitFor, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import EmojiMuteSettings from '../emoji_mute_settings';

const messages = {
  'emoji_mutes.title': 'Muted emoji',
  'emoji_mutes.subtitle': 'Subtitle',
  'emoji_mutes.loading': 'Loading muted emoji…',
  'emoji_mutes.load_error': 'Could not load muted emoji',
  'emoji_mutes.retry': 'Try again',
  'emoji_mutes.empty': 'No muted emoji yet',
  'emoji_mutes.reveal': 'Show muted emoji ({count})',
  'emoji_mutes.hide_list': 'Hide list',
  'emoji_mutes.search': 'Search muted emoji',
  'emoji_mutes.identity': 'Identity',
  'emoji_mutes.replacement': 'Replacement text',
  'emoji_mutes.effects': 'Effects',
  'emoji_mutes.effect.replace_in_text': 'Replace in text (stored)',
  'emoji_mutes.effect.reject_reactions_to_own_posts': 'Reject reactions on your posts',
  'emoji_mutes.effect.hide_reactions': 'Hide reactions',
  'emoji_mutes.effect.hide_in_picker': 'Hide in pickers (stored)',
  'emoji_mutes.save': 'Save changes',
  'emoji_mutes.saving': 'Saving…',
  'emoji_mutes.saved': 'Saved',
  'emoji_mutes.discard': 'Discard changes',
  'emoji_mutes.remove': 'Unmute',
  'emoji_mutes.removing': 'Removing…',
  'emoji_mutes.conflict': 'Conflict',
  'emoji_mutes.reload_rule': 'Reload saved rule',
  'emoji_mutes.save_error': 'Could not save this mute',
  'emoji_mutes.remove_error': 'Could not unmute',
  'emoji_mutes.unavailable': 'Unavailable or deleted',
  'emoji_mutes.disabled': 'Disabled',
  'emoji_mutes.unfetched': 'Remote image not cached',
  'emoji_mutes.kind.unicode': 'Unicode',
  'emoji_mutes.kind.local': 'Local custom',
  'emoji_mutes.kind.remote': 'Remote custom',
  'emoji_mutes.preview_hidden': 'Preview hidden',
  'emoji_mutes.show_preview': 'Show preview',
  'emoji_mutes.hide_preview': 'Hide preview',
  'emoji_mutes.preview_unavailable': 'Preview is unavailable for this emoji.',
  'emoji_mutes.preview_loading': 'Loading preview…',
  'emoji_mutes.open_details': 'Open details',
  'emoji_mutes.count': '{count} muted emoji',
  'emoji_mutes.dirty': 'Unsaved changes',
  'emoji_mutes.applied_note': 'Applied note',
  'emoji_mutes.javascript_required': 'Enable JavaScript',
};

const documentFixture = {
  revision: '3',
  effect_application: {
    applied: ['reject_reactions_to_own_posts', 'hide_reactions'],
    stored_only: ['replace_in_text', 'hide_in_picker'],
  },
  emoji_mutes: [
    {
      id: '10',
      revision: '3',
      emoji: { kind: 'unicode', native: '😀' },
      effects: {
        replace_in_text: true,
        reject_reactions_to_own_posts: true,
        hide_reactions: true,
        hide_in_picker: true,
      },
      replacement: '［絵文字］',
      detail: { state: 'resolved', kind: 'unicode', emoji_id: 'grinning' },
    },
  ],
};

function renderEditor(overrides = {}) {
  const loadDocument = jest.fn(() => Promise.resolve(documentFixture));
  const updateRule = jest.fn(() => Promise.resolve({
    revision: '4',
    emoji_mute: {
      ...documentFixture.emoji_mutes[0],
      revision: '4',
      replacement: 'x',
      effects: {
        replace_in_text: false,
        reject_reactions_to_own_posts: true,
        hide_reactions: true,
        hide_in_picker: false,
      },
    },
  }));
  const removeRule = jest.fn(() => Promise.resolve({ revision: '5' }));
  const resolveEmoji = jest.fn(() => Promise.resolve({
    reference: { kind: 'unicode', native: '😀' },
    detail: { image: { src: '/emoji/1f600.svg', alt: '😀' } },
  }));
  const onChanged = jest.fn();

  const utils = render(
    <IntlProvider locale='en' messages={messages}>
      <EmojiMuteSettings
        loadDocument={loadDocument}
        updateRule={updateRule}
        removeRule={removeRule}
        resolveEmoji={resolveEmoji}
        onChanged={onChanged}
        {...overrides}
      />
    </IntlProvider>,
  );

  return { ...utils, loadDocument, updateRule, removeRule, resolveEmoji, onChanged };
}

describe('EmojiMuteSettings', () => {
  it('keeps glyphs out of the initial DOM until the list is revealed', async () => {
    const { container } = renderEditor();

    await waitFor(() => expect(screen.getByText('Show muted emoji (1)')).toBeTruthy());

    expect(container.textContent).not.toContain('😀');
    expect(container.querySelector('img')).toBeNull();
    expect(container.innerHTML).not.toContain('grinning');
  });

  it('reveals identity text without painting the unicode glyph until preview', async () => {
    const { resolveEmoji } = renderEditor();

    await waitFor(() => expect(screen.getByText('Show muted emoji (1)')).toBeTruthy());
    fireEvent.click(screen.getByText('Show muted emoji (1)'));

    expect(screen.getByText(/Unicode · code points/)).toBeTruthy();
    expect(document.body.textContent).not.toContain('😀');
    expect(document.querySelector('img')).toBeNull();

    fireEvent.click(screen.getByText('Show preview'));
    await waitFor(() => expect(resolveEmoji).toHaveBeenCalled());
    await waitFor(() => expect(document.querySelector('img[src="/emoji/1f600.svg"]')).toBeTruthy());
    expect(document.querySelector('img').getAttribute('alt')).toBe('');
  });

  it('keeps dirty edits on conflict', async () => {
    const conflict = Object.assign(new Error('conflict'), { status: 409, code: 'conflict' });
    const updateRule = jest.fn(() => Promise.reject(conflict));
    renderEditor({ updateRule });

    await waitFor(() => expect(screen.getByText('Show muted emoji (1)')).toBeTruthy());
    fireEvent.click(screen.getByText('Show muted emoji (1)'));
    fireEvent.change(screen.getByDisplayValue('［絵文字］'), { target: { value: 'keep-me' } });
    fireEvent.click(screen.getByText('Save changes'));

    await waitFor(() => expect(screen.getByText('Conflict')).toBeTruthy());
    expect(screen.getByDisplayValue('keep-me')).toBeTruthy();
  });
});

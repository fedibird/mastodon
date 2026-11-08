import React from 'react';
import { IntlProvider } from 'react-intl';
import { render, waitFor } from '@testing-library/react';

import EmojiPickerShell from '../../emoji_picker_shell';
import { personalEmojiRequest } from '../api';
import StandardPicker from '../standard_picker';

jest.mock('../../emoji_picker_shell', () => jest.fn(() => null));
jest.mock('../api', () => ({ personalEmojiRequest: jest.fn() }));
jest.mock('mastodon/initial_state_data', () => ({
  __esModule: true,
  default: { meta: { auto_play_emoji: false } },
}));

it('includes categorized and uncategorized custom emoji with string category IDs under the project Babel configuration', async () => {
  const custom = (shortcode, category, visible = true) => ({
    shortcode,
    category,
    visible_in_picker: visible,
    url: `/emoji/${shortcode}.gif`,
    static_url: `/emoji/${shortcode}.png`,
    aliases: ['greeting'],
  });
  personalEmojiRequest.mockResolvedValue([
    custom('wave_custom', 'あいさつ'),
    custom('hello_custom', 'あいさつ'),
    custom('wide_banner', '横長'),
    custom('uncategorized'),
    custom('hidden', '非表示', false),
  ]);

  expect(personalEmojiRequest).not.toHaveBeenCalled();
  render(<IntlProvider locale='en'><StandardPicker onPick={jest.fn()} skinTone={1} onSkinToneChange={jest.fn()} /></IntlProvider>);
  await waitFor(() => expect(EmojiPickerShell).toHaveBeenCalled());

  expect(personalEmojiRequest).toHaveBeenCalledTimes(1);
  expect(personalEmojiRequest).toHaveBeenCalledWith('/api/v1/custom_emojis');
  const { custom: emojis, include } = EmojiPickerShell.mock.calls[0][0].standardPickerProps;

  expect(include).toEqual(expect.arrayContaining(['custom', 'custom-あいさつ', 'custom-横長', 'people', 'flags']));
  expect(include.every(id => typeof id === 'string')).toBe(true);
  expect(include.filter(id => id === 'custom-あいさつ')).toHaveLength(1);
  expect(include).not.toContain('custom-非表示');
  expect(emojis.map(emoji => emoji.id)).toEqual(['wave_custom', 'hello_custom', 'wide_banner', 'uncategorized']);
  expect(emojis[0]).toMatchObject({ custom: true, customCategory: 'あいさつ', short_names: ['wave_custom'], imageUrl: '/emoji/wave_custom.png' });
  expect(emojis[2]).toMatchObject({ custom: true, customCategory: '横長', short_names: ['wide_banner'] });
  expect(emojis[3]).toMatchObject({ custom: true, short_names: ['uncategorized'] });
});

import React from 'react';
import { render } from '@testing-library/react';
import nimblePickerData from '../emoji_mart_nimble_data';

const mockPickerProps = [];
const mockEmojiProps = [];

jest.mock('emoji-mart/dist-es/components/picker/nimble-picker', () => {
  return function MockNimblePicker(props) {
    mockPickerProps.push(props);
    return null;
  };
});

jest.mock('emoji-mart/dist-es/components/emoji/nimble-emoji', () => {
  return function MockNimbleEmoji(props) {
    mockEmojiProps.push(props);
    return null;
  };
});

import { Emoji, Picker } from '../emoji_picker';

describe('standard emoji picker adapters', () => {
  beforeEach(() => {
    mockPickerProps.length = 0;
    mockEmojiProps.length = 0;
  });

  it('binds the standard Nimble dataset into both Picker and Emoji', () => {
    const callerData = { emojis: {} };

    render(<Picker data={callerData} custom={[]} />);
    render(<Emoji data={callerData} emoji='fist' set='twitter' skin={2} />);

    expect(mockPickerProps[0].data).toBe(nimblePickerData);
    expect(mockEmojiProps[0].data).toBe(nimblePickerData);
    expect(mockPickerProps[0].data).not.toBe(callerData);
    expect(mockPickerProps[0].custom).toEqual([]);
    expect(mockEmojiProps[0].emoji).toBe('fist');
    expect(mockEmojiProps[0].skin).toBe(2);
    expect(nimblePickerData.emojis.fist.skin_variations['1F3FB']).toBeDefined();
    expect(nimblePickerData.emojis.sleuth_or_spy).toBeDefined();
  });
});

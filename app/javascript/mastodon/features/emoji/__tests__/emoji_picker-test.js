/* eslint-disable react/prop-types */

import React from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { Emoji, Picker } from '../emoji_picker';
import nimblePickerData from '../emoji_mart_nimble_data';

const mockPickers = [];
const mockEmojiProps = [];
let mockCategoryTop = 100;

jest.mock('emoji-mart/dist-es/components/emoji/nimble-emoji', () => {
  return function MockNimbleEmoji(props) {
    mockEmojiProps.push(props);
    return null;
  };
});
jest.mock('emoji-mart/dist-es/components/picker/nimble-picker', () => {
  const React = require('react');

  return class NimbleProbe extends React.PureComponent {

    constructor(props) {
      super(props);
      this.cachedTop = mockCategoryTop;
      this.updateCategoriesSize = jest.fn(() => {
        this.cachedTop = mockCategoryTop;
      });
      this.handleScroll = jest.fn();
      mockPickers.push(this);
    }

    setScrollRef = node => {
      this.scroll = node;
    };

    handleAnchorClick = () => {
      this.scroll.scrollTop = this.cachedTop + 1;
    };

    render() {
      return (
        <div>
          <button type='button' className='emoji-mart-anchor' onClick={this.handleAnchorClick}><span>People</span></button>
          <div className='emoji-mart-scroll' ref={this.setScrollRef}>
            <button type='button' className='emoji-mart-emoji-custom' onClick={this.props.onClick}><img src='/wide.png' alt='Wide custom' /></button>
            <img src='/other.png' alt='Other resource' />
          </div>
        </div>
      );
    }

  };
});

describe('standard emoji picker adapters', () => {
  let frames;
  let nextFrame;

  const paint = () => {
    const callbacks = Array.from(frames.values());
    frames.clear();
    callbacks.forEach(callback => callback());
  };

  beforeEach(() => {
    mockPickers.length = 0;
    mockEmojiProps.length = 0;
    mockCategoryTop = 100;
    frames = new Map();
    nextFrame = 0;
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      nextFrame += 1;
      frames.set(nextFrame, callback);
      return nextFrame;
    });
    jest.spyOn(window, 'cancelAnimationFrame').mockImplementation(id => frames.delete(id));
  });

  afterEach(() => {
    cleanup();
    jest.restoreAllMocks();
  });

  it('binds the standard Nimble dataset into both Picker and Emoji', () => {
    const callerData = { emojis: {} };

    render(<Picker data={callerData} custom={[]} />);
    render(<Emoji data={callerData} emoji='fist' set='twitter' skin={2} />);

    expect(mockPickers[0].props.data).toBe(nimblePickerData);
    expect(mockEmojiProps[0].data).toBe(nimblePickerData);
    expect(mockPickers[0].props.data).not.toBe(callerData);
    expect(mockPickers[0].props.custom).toEqual([]);
    expect(mockEmojiProps[0].emoji).toBe('fist');
    expect(mockEmojiProps[0].skin).toBe(2);
    expect(nimblePickerData.emojis.fist.skin_variations['1F3FB']).toBeDefined();
    expect(nimblePickerData.emojis.sleuth_or_spy).toBeDefined();
  });

  it('refreshes category positions once per frame after custom image loads or errors', () => {
    render(<Picker />);
    const picker = mockPickers[0];
    const image = screen.getByAltText('Wide custom');

    mockCategoryTop = 160;
    fireEvent.load(image);
    fireEvent.load(image);
    fireEvent.error(image);

    expect(frames.size).toBe(1);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
    act(paint);
    expect(picker.updateCategoriesSize).toHaveBeenCalledTimes(1);
    expect(picker.handleScroll).toHaveBeenCalledTimes(1);
    expect(picker.cachedTop).toBe(160);
  });

  it('measures before an anchor click and cancels a pending image frame', () => {
    render(<Picker />);
    const picker = mockPickers[0];

    mockCategoryTop = 220;
    fireEvent.load(screen.getByAltText('Wide custom'));
    fireEvent.click(screen.getByText('People'), { detail: 0 });

    expect(picker.scroll.scrollTop).toBe(221);
    expect(picker.updateCategoriesSize).toHaveBeenCalledTimes(1);
    expect(frames.size).toBe(0);
    act(paint);
    expect(picker.updateCategoriesSize).toHaveBeenCalledTimes(1);
  });

  it('ignores other resources and preserves emoji selection without measuring', () => {
    const onClick = jest.fn();
    render(<Picker onClick={onClick} />);
    const picker = mockPickers[0];

    fireEvent.load(screen.getByAltText('Other resource'));
    fireEvent.click(screen.getByAltText('Wide custom'));

    expect(frames.size).toBe(0);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('removes image and anchor listeners and cancels scheduled work on unmount', () => {
    const view = render(<Picker />);
    const picker = mockPickers[0];
    const image = screen.getByAltText('Wide custom');
    const anchor = screen.getByText('People');

    fireEvent.load(image);
    expect(frames.size).toBe(1);
    view.unmount();
    expect(frames.size).toBe(0);
    fireEvent.load(image);
    fireEvent.click(anchor);
    act(paint);
    expect(frames.size).toBe(0);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
  });
});

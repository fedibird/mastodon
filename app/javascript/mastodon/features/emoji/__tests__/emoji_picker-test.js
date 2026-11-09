/* eslint-disable react/prop-types */

import React from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import { Emoji, Picker, referenceFromMartButton } from '../emoji_picker';
import nimblePickerData from '../emoji_mart_nimble_data';
import { openEmojiActions, resetEmojiActionsBusForTests, setEmojiActionsListener } from '../emoji_actions/bus';

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
      this.state = { skin: props.skin || 1 };
      this.updateCategoriesSize = jest.fn(() => {
        this.cachedTop = mockCategoryTop;
      });
      this.handleScroll = jest.fn();
      this.handleEmojiOver = jest.fn();
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
            <button type='button' className='emoji-mart-emoji' title='thumbsup' aria-label='Thumbs Up Label, +1' onClick={this.props.onClick}><span role='img' aria-label='Thumbs Up Label'>{'\u{1F44D}'}</span></button>
            <button type='button' className='emoji-mart-emoji-custom' onClick={this.props.onClick}><img src='/wide.png' alt='Wide custom' /></button>
            <img src='/other.png' alt='Other resource' />
          </div>
        </div>
      );
    }

  };
});

const renderPicker = (ui) => render(<IntlProvider locale='en'>{ui}</IntlProvider>);

describe('standard emoji picker adapters', () => {
  let frames;
  let nextFrame;
  let resizeObserver;
  let notifyResize;
  const originalResizeObserver = window.ResizeObserver;

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
    window.ResizeObserver = jest.fn().mockImplementation(callback => {
      notifyResize = callback;
      resizeObserver = { observe: jest.fn(), disconnect: jest.fn() };
      return resizeObserver;
    });
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      nextFrame += 1;
      frames.set(nextFrame, callback);
      return nextFrame;
    });
    jest.spyOn(window, 'cancelAnimationFrame').mockImplementation(id => frames.delete(id));
  });

  afterEach(() => {
    cleanup();
    window.ResizeObserver = originalResizeObserver;
    jest.restoreAllMocks();
    resetEmojiActionsBusForTests();
  });

  it('binds the standard Nimble dataset into both Picker and Emoji', () => {
    const callerData = { emojis: {} };

    renderPicker(<Picker data={callerData} custom={[]} />);
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

  it('opens actions from Nimble selection data, not aria-label display names', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);

    const button = document.createElement('button');
    button.className = 'emoji-mart-emoji';
    button.setAttribute('title', 'thumbsup');
    button.setAttribute('aria-label', 'Thumbs Up Label, +1');

    const reference = referenceFromMartButton(button, 1);
    expect(reference).toEqual({ kind: 'unicode', native: expect.any(String) });
    expect(reference.native).not.toBe('Thumbs Up Label');

    openEmojiActions(reference, { anchor: button, source: 'standard_picker' });
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      reference: expect.objectContaining({ kind: 'unicode', native: reference.native }),
      source: 'standard_picker',
    }));
  });

  it('exposes a visible manage control driven by focused Nimble emoji data', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker />);

    const picker = mockPickers[0];
    const emoji = { id: 'thumbsup', native: '👍', colons: ':thumbsup:' };
    act(() => {
      picker.handleEmojiOver(emoji);
    });

    fireEvent.click(screen.getByLabelText('Emoji actions'));
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      reference: { kind: 'unicode', native: '👍' },
      source: 'standard_picker',
    }));
  });

  it('refreshes category positions once per frame after custom image loads or errors', () => {
    renderPicker(<Picker />);
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
    renderPicker(<Picker />);
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

  it('remeasures responsive picker dimensions once per frame together with image loads', () => {
    renderPicker(<Picker />);
    const picker = mockPickers[0];

    expect(resizeObserver.observe).toHaveBeenCalledWith(picker.scroll.parentNode);
    mockCategoryTop = 340;
    notifyResize();
    notifyResize();
    fireEvent.load(screen.getByAltText('Wide custom'));

    expect(frames.size).toBe(1);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
    act(paint);
    expect(picker.cachedTop).toBe(340);
    expect(picker.updateCategoriesSize).toHaveBeenCalledTimes(1);
    expect(picker.handleScroll).toHaveBeenCalledTimes(1);
  });

  it('handles window resizing without ResizeObserver and removes the fallback on unmount', () => {
    window.ResizeObserver = undefined;
    const view = renderPicker(<Picker />);
    const picker = mockPickers[0];

    mockCategoryTop = 420;
    fireEvent(window, new Event('resize'));
    act(paint);
    expect(picker.cachedTop).toBe(420);
    expect(picker.handleScroll).toHaveBeenCalledTimes(1);

    fireEvent(window, new Event('resize'));
    expect(frames.size).toBe(1);
    view.unmount();
    expect(frames.size).toBe(0);
    fireEvent(window, new Event('resize'));
    expect(frames.size).toBe(0);
  });

  it('ignores other resources and preserves emoji selection without measuring', () => {
    const onClick = jest.fn();
    renderPicker(<Picker onClick={onClick} />);
    const picker = mockPickers[0];

    fireEvent.load(screen.getByAltText('Other resource'));
    fireEvent.click(screen.getByAltText('Wide custom'));

    expect(frames.size).toBe(0);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('disconnects resizing, removes listeners and cancels scheduled work on unmount', () => {
    const view = renderPicker(<Picker />);
    const picker = mockPickers[0];
    const image = screen.getByAltText('Wide custom');
    const anchor = screen.getByText('People');

    fireEvent.load(image);
    notifyResize();
    expect(frames.size).toBe(1);
    view.unmount();
    expect(resizeObserver.disconnect).toHaveBeenCalledTimes(1);
    expect(frames.size).toBe(0);
    fireEvent.load(image);
    fireEvent.click(anchor);
    act(paint);
    expect(frames.size).toBe(0);
    expect(picker.updateCategoriesSize).not.toHaveBeenCalled();
  });
});

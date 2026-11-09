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
          <input type='search' aria-label='Search' className='emoji-mart-search' />
          <button type='button' className='emoji-mart-anchor' onClick={this.handleAnchorClick}><span>People</span></button>
          <div className='emoji-mart-scroll' ref={this.setScrollRef}>
            <ul className='emoji-mart-category-list'>
              <li>
                <button type='button' className='emoji-mart-emoji' title='thumbsup' aria-label='Thumbs Up Label, +1' onClick={this.props.onClick}>
                  <span role='img' aria-label='Thumbs Up Label'>{'\u{1F44D}'}</span>
                </button>
              </li>
              <li>
                <button type='button' className='emoji-mart-emoji' title='heart' aria-label='Red Heart Label' onClick={this.props.onClick}>
                  <span role='img' aria-label='Red Heart Label'>{'\u{2764}\u{FE0F}'}</span>
                </button>
              </li>
              <li>
                <button type='button' className='emoji-mart-emoji' title='blob' aria-label='Blob Custom' onClick={this.props.onClick}>
                  <span className='emoji-mart-emoji-custom'><img src='/wide.png' alt='Wide custom' /></span>
                </button>
              </li>
            </ul>
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

  it('uses the event cell for Shift+F10, not a previous hover selection', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker />);

    const picker = mockPickers[0];
    const thumb = screen.getByTitle('thumbsup');
    const heart = screen.getByTitle('heart');

    act(() => {
      picker.handleEmojiOver({ id: 'thumbsup', native: '👍', colons: ':thumbsup:' });
    });

    heart.focus();
    fireEvent.keyDown(heart, { key: 'F10', shiftKey: true });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].reference).toEqual(
      referenceFromMartButton(heart, 1),
    );
    expect(listener.mock.calls[0][0].reference.native).not.toBe('👍');
    expect(thumb).toBeTruthy();
  });

  it('no-ops Shift+F10 on the search field even after a prior hover', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker />);

    const picker = mockPickers[0];
    act(() => {
      picker.handleEmojiOver({ id: 'thumbsup', native: '👍', colons: ':thumbsup:' });
    });

    const search = screen.getByLabelText('Search');
    search.focus();
    fireEvent.keyDown(search, { key: 'F10', shiftKey: true });

    expect(listener).not.toHaveBeenCalled();
  });

  it('opens context menu actions for the right-clicked cell only', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker />);

    const picker = mockPickers[0];
    act(() => {
      picker.handleEmojiOver({ id: 'thumbsup', native: '👍', colons: ':thumbsup:' });
    });

    const heart = screen.getByTitle('heart');
    fireEvent.contextMenu(heart);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].reference).toEqual(referenceFromMartButton(heart, 1));
  });

  it('hides cell and bar manage controls outside edit mode', () => {
    renderPicker(<Picker />);

    expect(document.querySelector('.emoji-mart-emoji-actions')).toBeNull();
    expect(screen.queryByLabelText('Emoji actions')).toBeNull();
  });

  it('enables the manage control from keyboard focus without hover in edit mode', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker editMode />);

    expect(screen.getByLabelText('Emoji actions')).toBeDisabled();

    const heart = screen.getByTitle('heart');
    fireEvent.focusIn(heart);

    expect(screen.getByLabelText('Emoji actions')).not.toBeDisabled();
    fireEvent.click(screen.getByLabelText('Emoji actions'));

    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      reference: referenceFromMartButton(heart, 1),
      source: 'standard_picker',
    }));
  });

  it('opens per-cell manage without inserting through the normal click path', () => {
    const listener = jest.fn();
    const onClick = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker editMode onClick={onClick} />);

    const heart = screen.getByTitle('heart');
    const cellActions = heart.parentElement.querySelector('[data-emoji-actions="1"]');
    expect(cellActions).toBeTruthy();

    // Mouse/pointer series on the independent manage control must not insert.
    fireEvent.pointerDown(cellActions);
    fireEvent.pointerUp(cellActions);
    fireEvent.click(cellActions);

    expect(onClick).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].reference).toEqual(referenceFromMartButton(heart, 1));
  });

  it('opens per-cell manage on touchend when no synthetic click is delivered', () => {
    const listener = jest.fn();
    const onClick = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker editMode onClick={onClick} />);

    const heart = screen.getByTitle('heart');
    const cellActions = heart.parentElement.querySelector('[data-emoji-actions="1"]');
    const touch = { identifier: 1, clientX: 12, clientY: 12 };

    fireEvent.touchStart(cellActions, { touches: [touch] });
    fireEvent.touchEnd(cellActions, { changedTouches: [touch] });
    // UA suppressed click — manage must already be open.
    expect(listener).toHaveBeenCalledTimes(1);
    expect(onClick).not.toHaveBeenCalled();
  });

  it('does not double-open when touchend is followed by a synthetic click', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker editMode />);

    const heart = screen.getByTitle('heart');
    const cellActions = heart.parentElement.querySelector('[data-emoji-actions="1"]');
    const touch = { identifier: 2, clientX: 4, clientY: 4 };

    fireEvent.touchStart(cellActions, { touches: [touch] });
    fireEvent.touchEnd(cellActions, { changedTouches: [touch] });
    fireEvent.click(cellActions);

    expect(listener).toHaveBeenCalledTimes(1);
  });

  it('opens manage from a long-press on the emoji cell without inserting', () => {
    jest.useFakeTimers();
    const listener = jest.fn();
    const onClick = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker onClick={onClick} />);

    const heart = screen.getByTitle('heart');
    const touch = { identifier: 9, clientX: 1, clientY: 1 };
    fireEvent.touchStart(heart, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(520);
    });
    fireEvent.touchEnd(heart, { changedTouches: [touch] });
    // Synthetic follow-up click uses detail >= 1; detail 0 is a11y and must not be suppressed.
    fireEvent.click(heart, { detail: 1 });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(onClick).not.toHaveBeenCalled();
    jest.useRealTimers();
  });

  it('keeps normal emoji tap insertion (pointerdown → click → onClick)', () => {
    const listener = jest.fn();
    const onClick = jest.fn();
    setEmojiActionsListener(listener);
    renderPicker(<Picker onClick={onClick} />);

    const heart = screen.getByTitle('heart');
    fireEvent.pointerDown(heart);
    fireEvent.pointerUp(heart);
    fireEvent.click(heart);

    expect(onClick).toHaveBeenCalledTimes(1);
    expect(listener).not.toHaveBeenCalled();
  });

  it('resolves local custom rows from title + custom catalog, not aria-label', () => {
    const custom = [{
      id: 'blob',
      name: 'blob',
      short_names: ['blob'],
      custom: true,
      custom_emoji_id: '42',
      imageUrl: '/wide.png',
    }];
    const button = document.createElement('button');
    button.className = 'emoji-mart-emoji';
    button.setAttribute('title', 'blob');
    button.setAttribute('aria-label', 'Blob Display Name');

    expect(referenceFromMartButton(button, 1, custom)).toEqual({
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: '42',
      shortcode: 'blob',
    });
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

import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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
  };
});

import ComposerMediaGallery from '../components/composer_media_gallery';
import { moveMediaIds, summaryThumbCount, visibleMediaWindow } from '../composer_media';

const media = (id, type = 'image') => ImmutableMap({
  id,
  type,
  preview_url: type === 'audio' ? null : `/preview/${id}.jpg`,
  description: `${id} alt`,
});

const renderGallery = (items, props = {}) => {
  const onEdit = jest.fn();
  const onRemove = jest.fn();
  const onMoveTo = jest.fn();
  const onMoveBy = jest.fn();

  render(
    <ComposerMediaGallery
      media={ImmutableList(items)}
      onEdit={onEdit}
      onRemove={onRemove}
      onMoveTo={onMoveTo}
      onMoveBy={onMoveBy}
      {...props}
    />,
  );

  return { onEdit, onRemove, onMoveTo, onMoveBy };
};

describe('composer media order', () => {
  it('moves an attachment to any index and summarizes five or seven items', () => {
    expect(moveMediaIds(['a', 'b', 'c', 'd'], 'a', 2)).toEqual(['b', 'c', 'a', 'd']);
    expect(moveMediaIds(['a', 'b', 'c'], 'c', 0)).toEqual(['c', 'a', 'b']);
    expect(moveMediaIds(['a', 'b'], 'a', 0)).toEqual(['a', 'b']);
    expect(visibleMediaWindow([], { summary: true })).toEqual({ visible: [], overflow: 0 });
    expect(visibleMediaWindow(['a'], { summary: true }).overflow).toBe(0);
    expect(visibleMediaWindow(['a', 'b', 'c', 'd'], { summary: true }).visible).toEqual(['a', 'b', 'c', 'd']);
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e'], { summary: true })).toEqual({
      visible: ['a', 'b', 'c', 'd'],
      overflow: 1,
    });
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e', 'f', 'g'], { summary: true })).toEqual({
      visible: ['a', 'b', 'c', 'd'],
      overflow: 3,
    });
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e', 'f', 'g'], { summary: true, expanded: true }).overflow).toBe(0);
    expect(summaryThumbCount({ width: 0, itemCount: 7 })).toBe(4);
    expect(summaryThumbCount({ width: 320, itemCount: 7, reserved: 180 })).toBe(2);
    expect(summaryThumbCount({ width: 120, itemCount: 7, reserved: 80 })).toBe(0);
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e'], { summary: true, limit: 0 })).toEqual({
      visible: [],
      overflow: 5,
    });
  });
});

describe('ComposerMediaGallery', () => {
  it('shows no thumbnail row when nothing is attached', () => {
    renderGallery([]);

    expect(screen.queryByTestId('composer-media')).toBeNull();
  });

  it('opens edit and delete from a thumbnail menu and moves with the keyboard', () => {
    const { onEdit, onRemove, onMoveBy } = renderGallery([media('a'), media('b', 'video'), media('c', 'audio')]);

    fireEvent.click(screen.getByRole('button', { name: 'a alt' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Edit' }));
    expect(onEdit).toHaveBeenCalledWith('a');

    fireEvent.click(screen.getByRole('button', { name: 'c alt' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' }));
    expect(onRemove).toHaveBeenCalledWith('c');

    fireEvent.keyDown(screen.getByRole('button', { name: 'b alt' }), { key: 'ArrowLeft' });
    fireEvent.keyDown(screen.getByRole('button', { name: 'b alt' }), { key: 'ArrowRight' });

    expect(onMoveBy).toHaveBeenNthCalledWith(1, 'b', -1);
    expect(onMoveBy).toHaveBeenNthCalledWith(2, 'b', 1);
    expect(screen.getByRole('button', { name: 'c alt' }).querySelector('.fa-music, .icon')).toBeTruthy();
  });

  it('summarizes seven attachments as four thumbnails and +3, then expands', () => {
    const items = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map(id => media(id));
    renderGallery(items, { summary: true });

    expect(screen.getAllByRole('button', { name: /alt$/ })).toHaveLength(4);
    fireEvent.click(screen.getByRole('button', { name: 'Show 3 more attachments' }));

    expect(screen.getAllByRole('button', { name: /alt$/ })).toHaveLength(7);
  });

  it('drops a dragged attachment onto a new index and restores on cancel', () => {
    const { onMoveTo } = renderGallery([media('a'), media('b'), media('c'), media('d')]);
    const items = document.querySelectorAll('.compose-form__media-item');
    const first = items[0];
    const third = items[2];

    items.forEach((node, index) => {
      node.getBoundingClientRect = () => ({ left: index * 40, right: index * 40 + 36, top: 0, bottom: 36, width: 36, height: 36 });
    });

    const point = (type, node, x, y, pointerType = 'mouse') => {
      const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });

      Object.defineProperty(event, 'pointerId', { value: 1 });
      Object.defineProperty(event, 'pointerType', { value: pointerType });
      fireEvent(node, event);
    };

    const capture = jest.fn();

    first.setPointerCapture = capture;

    point('pointerdown', first, 10, 10);
    expect(capture).not.toHaveBeenCalled();

    point('pointermove', first, 12, 10);
    expect(capture).not.toHaveBeenCalled();

    point('pointermove', first, 90, 10);
    expect(capture).toHaveBeenCalledWith(1);

    expect(first).toHaveClass('is-dragging');
    expect(third).toHaveClass('is-drop-target');

    point('pointerup', first, 90, 10);

    expect(onMoveTo).toHaveBeenCalledWith('a', 2);
    expect(first).not.toHaveClass('is-dragging');

    onMoveTo.mockClear();
    point('pointerdown', first, 10, 10);
    point('pointermove', first, 90, 10);
    fireEvent(first, new Event('pointercancel', { bubbles: true }));

    expect(onMoveTo).not.toHaveBeenCalled();
    expect(first).not.toHaveClass('is-dragging');
  });

  it('opens the menu on a click or tap and does not treat menu actions as a drag', () => {
    const { onEdit, onMoveTo } = renderGallery([media('a'), media('b')]);
    const thumb = screen.getByRole('button', { name: 'a alt' });
    const item = thumb.parentElement;
    const point = (type, node, x, y, pointerType) => {
      const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });

      Object.defineProperty(event, 'pointerId', { value: 7 });
      Object.defineProperty(event, 'pointerType', { value: pointerType });
      fireEvent(node, event);
    };

    fireEvent.click(thumb);
    expect(screen.getByRole('menu', { name: 'Attachment options' })).toBeTruthy();
    fireEvent.click(thumb);

    point('pointerdown', item, 8, 8, 'touch');
    point('pointerup', item, 8, 8, 'touch');
    fireEvent.click(thumb);

    expect(screen.getByRole('menu', { name: 'Attachment options' })).toBeTruthy();
    expect(onMoveTo).not.toHaveBeenCalled();

    const edit = screen.getByRole('menuitem', { name: 'Edit' });

    point('pointerdown', edit, 8, 8, 'mouse');
    point('pointermove', edit, 80, 8, 'mouse');
    fireEvent.click(edit);

    expect(onMoveTo).not.toHaveBeenCalled();
    expect(onEdit).toHaveBeenCalledWith('a');
  });
});

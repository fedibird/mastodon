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
import { attachmentUploadBlocked, composerFileDropBlock, moveMediaIds, summaryThumbCount, visibleMediaWindow } from '../composer_media';

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
    expect(summaryThumbCount({ width: 300, itemCount: 7 })).toBe(4);
    expect(summaryThumbCount({ width: 2000, itemCount: 7 })).toBe(4);
    expect(summaryThumbCount({ width: 2000, itemCount: 3 })).toBe(3);
    expect(summaryThumbCount({ width: 320, itemCount: 7, reserved: 180 })).toBe(2);
    expect(summaryThumbCount({ width: 120, itemCount: 7, reserved: 80 })).toBe(0);
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e', 'f', 'g'], { summary: true }).overflow).toBe(3);
    expect(visibleMediaWindow(['a', 'b', 'c', 'd', 'e'], { summary: true, limit: 0 })).toEqual({
      visible: [],
      overflow: 5,
    });
    expect(attachmentUploadBlocked({ incomingMimeTypes: ['video/mp4'] })).toBe(false);
    expect(attachmentUploadBlocked({ incomingMimeTypes: ['image/png', 'image/jpeg'] })).toBe(false);
    expect(attachmentUploadBlocked({ existingTypes: ['video'], incomingMimeTypes: ['image/png'] })).toBe(true);
    expect(attachmentUploadBlocked({ existingTypes: ['image'], incomingMimeTypes: ['video/mp4'] })).toBe(true);
    expect(attachmentUploadBlocked({ existingTypes: ['audio'], incomingMimeTypes: ['image/png'] })).toBe(true);
    expect(attachmentUploadBlocked({ incomingMimeTypes: ['video/mp4', 'image/png'] })).toBe(true);
    expect(attachmentUploadBlocked({ incomingMimeTypes: ['video/mp4', 'video/webm'] })).toBe(true);
    expect(attachmentUploadBlocked({ pending: 1, incomingMimeTypes: ['audio/mpeg'] })).toBe(true);
    expect(attachmentUploadBlocked({ pendingExclusive: 1, incomingMimeTypes: ['image/png'] })).toBe(true);
    expect(attachmentUploadBlocked({ pending: 1, pendingExclusive: 0, incomingMimeTypes: ['image/jpeg'] })).toBe(false);
    expect(attachmentUploadBlocked({ existingTypes: ['image'], pending: 1, incomingMimeTypes: ['image/png'] })).toBe(false);
    expect(composerFileDropBlock({ mediaCount: 4, maxAttachments: 4 })).toBe('limit');
    expect(composerFileDropBlock({ mediaCount: 3, pending: 1, maxAttachments: 4 })).toBe('limit');
    expect(composerFileDropBlock({ existingTypes: ['video'], mediaCount: 1, maxAttachments: 4 })).toBe('video');
    expect(composerFileDropBlock({ existingTypes: ['audio'], mediaCount: 1, maxAttachments: 4 })).toBe('video');
    expect(composerFileDropBlock({ pending: 1, pendingExclusive: 1, maxAttachments: 4 })).toBe('video');
    expect(composerFileDropBlock({ hasPoll: true, allowPollImage: false, maxAttachments: 4 })).toBe('poll_image');
    expect(composerFileDropBlock({ hasPoll: true, allowPollImage: true, mediaCount: 1, existingTypes: ['image'], maxAttachments: 4 })).toBeNull();
    expect(composerFileDropBlock({ existingTypes: ['image'], mediaCount: 1, pending: 1, maxAttachments: 4 })).toBeNull();
    expect(composerFileDropBlock({
      existingTypes: ['image'],
      mediaCount: 1,
      pending: 1,
      maxAttachments: 4,
      incomingMimeTypes: ['video/mp4'],
    })).toBe('video');
    expect(composerFileDropBlock({ canUpload: false, permissionReason: 'unauthorized', maxAttachments: 4 })).toBe('unauthorized');
    expect(composerFileDropBlock({ existingTypes: ['image'], mediaCount: 2, maxAttachments: 4 })).toBeNull();
    expect(composerFileDropBlock({ mediaCount: 4, maxAttachments: 4 })).toBe('limit');
    expect(composerFileDropBlock({ mediaCount: 0, maxAttachments: 4 })).toBeNull();
    expect(composerFileDropBlock({
      mediaCount: 0,
      maxAttachments: 4,
      incomingMimeTypes: ['image/png', 'image/png', 'image/png', 'image/png', 'image/png'],
    })).toBe('limit');
    expect(composerFileDropBlock({
      existingTypes: ['image', 'image', 'image'],
      mediaCount: 3,
      maxAttachments: 4,
      incomingMimeTypes: ['image/png', 'image/png'],
    })).toBe('limit');
    expect(composerFileDropBlock({
      existingTypes: ['image', 'image'],
      mediaCount: 2,
      pending: 1,
      maxAttachments: 4,
      incomingMimeTypes: ['image/png', 'image/png'],
    })).toBe('limit');
    expect(composerFileDropBlock({
      existingTypes: ['image', 'image'],
      mediaCount: 2,
      maxAttachments: 4,
      incomingMimeTypes: ['image/png', 'image/png'],
    })).toBeNull();
    expect(composerFileDropBlock({
      existingTypes: ['image', 'image', 'image'],
      mediaCount: 3,
      maxAttachments: 4,
      incomingMimeTypes: ['image/png'],
    })).toBeNull();
    expect(composerFileDropBlock({ mediaCount: 3, maxAttachments: 4 })).toBeNull();
  });
});

describe('ComposerMediaGallery', () => {
  it('shows no thumbnail row when nothing is attached', () => {
    renderGallery([]);

    expect(screen.queryByTestId('composer-media')).toBeNull();
  });

  it('edits from the thumbnail, removes from the corner, and moves with the keyboard', () => {
    const { onEdit, onRemove, onMoveBy } = renderGallery([media('a'), media('b', 'video'), media('c', 'audio')]);

    fireEvent.click(screen.getByRole('button', { name: 'a alt' }));
    expect(onEdit).toHaveBeenCalledWith('a');
    expect(screen.queryByRole('menu')).toBeNull();
    expect(document.querySelector('.compose-form__media-handle')).toBeNull();

    fireEvent.click(screen.getAllByRole('button', { name: 'Delete' })[2]);
    expect(onRemove).toHaveBeenCalledWith('c');

    fireEvent.keyDown(screen.getByRole('button', { name: 'b alt' }), { key: 'ArrowLeft' });
    fireEvent.keyDown(screen.getByRole('button', { name: 'b alt' }), { key: 'ArrowRight' });

    expect(onMoveBy).toHaveBeenNthCalledWith(1, 'b', -1);
    expect(onMoveBy).toHaveBeenNthCalledWith(2, 'b', 1);
    expect(screen.getByRole('button', { name: 'c alt' }).querySelector('.fa-music, .icon')).toBeTruthy();
    expect(screen.getByRole('status').textContent).toContain('Only one video or audio file');
  });

  it('summarizes seven attachments as four thumbnails and +3, then expands', () => {
    const items = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map(id => media(id));
    renderGallery(items, { summary: true });

    expect(screen.getAllByRole('button', { name: /alt$/ })).toHaveLength(4);
    expect(document.querySelector('.compose-form__media-handle')).toBeNull();
    expect(screen.getByRole('button', { name: 'Show 3 more attachments' })).toHaveTextContent('+3');

    fireEvent.click(screen.getByRole('button', { name: 'Show 3 more attachments' }));

    expect(screen.getAllByRole('button', { name: /alt$/ })).toHaveLength(7);
    expect(screen.queryByRole('button', { name: 'Show 3 more attachments' })).toBeNull();
    expect(document.querySelector('.compose-form__media-handle')).toBeNull();
  });

  it('shows every full-size thumbnail without a summary card', () => {
    const items = ['a', 'b', 'c', 'd', 'e'].map(id => media(id));
    renderGallery(items);

    expect(screen.getAllByRole('button', { name: /alt$/ })).toHaveLength(5);
    expect(screen.queryByText('+1')).toBeNull();
    expect(screen.getByRole('status').textContent).toContain('can’t be added while images are attached');
  });

  it('drops a dragged attachment onto a new index and restores on cancel', () => {
    const { onMoveTo } = renderGallery([media('a'), media('b'), media('c'), media('d')]);
    const items = document.querySelectorAll('.compose-form__media-item');
    const first = items[0];

    items.forEach((node, index) => {
      node.getBoundingClientRect = () => ({ left: index * 40, right: index * 40 + 36, top: 0, bottom: 36, width: 36, height: 36 });
    });

    const point = (type, node, x, y, pointerType = 'mouse') => {
      const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });

      Object.defineProperty(event, 'pointerId', { value: 1 });
      Object.defineProperty(event, 'pointerType', { value: pointerType });
      fireEvent(node, event);
    };

    const thumb = first.querySelector('.compose-form__media-thumb');
    const capture = jest.fn();

    thumb.setPointerCapture = capture;

    point('pointerdown', thumb, 10, 10);
    expect(capture).not.toHaveBeenCalled();

    point('pointermove', thumb, 12, 10);
    expect(capture).not.toHaveBeenCalled();

    const labels = () => screen.getAllByRole('button', { name: /alt$/ }).map(node => node.getAttribute('aria-label'));

    point('pointermove', thumb, 90, 10);
    expect(capture).toHaveBeenCalledWith(1);

    expect(first).toHaveClass('is-dragging');
    expect(onMoveTo).not.toHaveBeenCalled();
    expect(labels()).toEqual(['b alt', 'c alt', 'a alt', 'd alt']);

    point('pointerup', thumb, 90, 10);

    expect(onMoveTo).toHaveBeenCalledWith('a', 2);
    expect(first).not.toHaveClass('is-dragging');

    onMoveTo.mockClear();
    point('pointerdown', thumb, 10, 10);
    point('pointermove', thumb, 90, 10);
    expect(labels()).toEqual(['b alt', 'c alt', 'a alt', 'd alt']);
    fireEvent(thumb, new Event('pointercancel', { bubbles: true }));

    expect(onMoveTo).not.toHaveBeenCalled();
    expect(first).not.toHaveClass('is-dragging');
    expect(labels()).toEqual(['a alt', 'b alt', 'c alt', 'd alt']);
  });

  it('opens edit on a click or tap and does not treat the remove button as a drag', () => {
    const { onEdit, onRemove, onMoveTo } = renderGallery([media('a'), media('b')]);
    const thumb = screen.getByRole('button', { name: 'a alt' });
    const remove = thumb.parentElement.querySelector('.compose-form__media-remove');
    const point = (type, node, x, y, pointerType) => {
      const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });

      Object.defineProperty(event, 'pointerId', { value: 7 });
      Object.defineProperty(event, 'pointerType', { value: pointerType });
      fireEvent(node, event);
    };

    fireEvent.click(thumb);
    expect(onEdit).toHaveBeenCalledWith('a');
    expect(screen.queryByRole('menu')).toBeNull();

    point('pointerdown', thumb, 8, 8, 'touch');
    point('pointerup', thumb, 8, 8, 'touch');
    fireEvent.click(thumb);

    expect(onMoveTo).not.toHaveBeenCalled();
    expect(onEdit).toHaveBeenCalledTimes(2);

    point('pointerdown', remove, 8, 8, 'mouse');
    point('pointermove', remove, 80, 8, 'mouse');
    fireEvent.click(remove);

    expect(onMoveTo).not.toHaveBeenCalled();
    expect(onRemove).toHaveBeenCalledWith('a');
  });

  it('opens edit on the next click after a cancelled drag', () => {
    const { onEdit, onMoveTo } = renderGallery([media('a'), media('b'), media('c')]);
    const thumb = screen.getByRole('button', { name: 'a alt' });
    const point = (type, node, x, y) => {
      const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });

      Object.defineProperty(event, 'pointerId', { value: 4 });
      fireEvent(node, event);
    };

    point('pointerdown', thumb, 4, 4);
    point('pointermove', thumb, 40, 30);
    fireEvent(thumb, new Event('pointercancel', { bubbles: true }));

    expect(onMoveTo).not.toHaveBeenCalled();
    fireEvent.click(thumb);

    expect(onEdit).toHaveBeenCalledWith('a');
    expect(screen.queryByRole('menu')).toBeNull();
  });
});

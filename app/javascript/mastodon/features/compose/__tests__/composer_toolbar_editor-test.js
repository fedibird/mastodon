import { fireEvent } from '@testing-library/react';

import { dumpComposerToolbar, normalizeComposerToolbar } from '../composer_toolbar';
import { installComposerToolbarEditor } from '../composer_toolbar_editor';

const labels = {
  drag: 'Drag to reorder',
  placement: 'Placement',
  moveUp: 'Move up',
  moveDown: 'Move down',
  placements: { visible: 'Show', menu: 'Menu', hidden: 'Hide' },
  items: {
    posting_account: 'Posting account',
    media: 'Attach media',
    cw: 'Content warning',
    language: 'Language',
    datetime: 'Publish and expiry time',
    searchability: 'Search visibility',
    poll: 'Poll',
  },
  icons: {
    posting_account: 'user',
    media: 'paperclip',
    cw: 'warning',
    language: 'globe',
    datetime: 'calendar',
    searchability: 'search',
    poll: 'tasks',
  },
};

const mount = () => {
  const initial = dumpComposerToolbar(normalizeComposerToolbar(null));
  const form = document.createElement('form');
  const root = document.createElement('div');
  const field = document.createElement('input');
  const list = document.createElement('ul');
  const cancel = document.createElement('button');

  field.type = 'hidden';
  field.dataset.composerToolbarField = 'true';
  list.dataset.composerToolbarList = 'true';
  cancel.type = 'button';
  cancel.dataset.composerToolbarCancel = 'true';
  root.dataset.composerToolbarEditor = 'true';
  root.dataset.initial = initial;
  root.dataset.labels = JSON.stringify(labels);
  root.dataset.unsaved = 'Leave without saving?';
  root.append(field, list, cancel);
  form.appendChild(root);
  document.body.appendChild(form);

  const cleanup = installComposerToolbarEditor(root);
  const rows = () => {
    const result = [];

    for (let index = 0; index < list.children.length; index += 1) {
      result.push(list.children[index]);
    }

    return result;
  };
  const layout = () => {
    rows().forEach((row, index) => {
      row.getBoundingClientRect = () => ({
        top: index * 40,
        height: 40,
        bottom: (index * 40) + 40,
        left: 0,
        right: 200,
        width: 200,
      });
    });
  };

  layout();

  return { root, field, list, cancel, rows, layout, cleanup };
};

const dispatchPointer = (type, target, clientY) => {
  const event = new Event(type, { bubbles: true, cancelable: true });

  Object.defineProperties(event, {
    pointerId: { value: 1 },
    pointerType: { value: 'touch' },
    button: { value: 0 },
    clientY: { value: clientY },
  });
  target.dispatchEvent(event);
};

describe('composer toolbar editor', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('swaps rows while the pointer is still down', () => {
    const view = mount();
    const handle = view.rows()[1].querySelector('[data-drag-handle]');

    dispatchPointer('pointerdown', handle, 50);
    expect(view.rows().map(row => row.dataset.id)[1]).toEqual('media');

    view.layout();
    dispatchPointer('pointermove', document, 101);

    expect(view.rows().map(row => row.dataset.id).slice(0, 3)).toEqual(['posting_account', 'cw', 'media']);
    expect(view.field.value).toContain('v1|posting_account:visible|cw:visible|media:visible');
    expect(view.root.dataset.dirty).toEqual('true');

    dispatchPointer('pointerup', document, 101);

    expect(view.rows().map(row => row.dataset.id).slice(0, 3)).toEqual(['posting_account', 'cw', 'media']);
    view.cleanup();
  });

  it('moves a row from the keyboard and from the buttons', () => {
    const view = mount();
    const handle = view.rows()[3].querySelector('[data-drag-handle]');

    handle.focus();
    fireEvent.keyDown(handle, { key: 'ArrowUp' });

    expect(view.rows().map(row => row.dataset.id)[2]).toEqual('language');
    expect(document.activeElement).toBe(view.rows()[2].querySelector('[data-drag-handle]'));

    fireEvent.click(view.rows()[2].querySelector('[data-move="up"]'));

    expect(view.rows().map(row => row.dataset.id)[1]).toEqual('language');
    view.cleanup();
  });

  it('keeps placement edits in the draft until cancel', () => {
    const saved = dumpComposerToolbar(normalizeComposerToolbar(null));
    const view = mount();
    const select = view.rows()[0].querySelector('[data-placement]');

    fireEvent.change(select, { target: { value: 'hidden' } });

    expect(view.field.value).toContain('posting_account:hidden');
    expect(view.root.dataset.dirty).toEqual('true');
    expect(view.field.value).not.toEqual(saved);

    fireEvent.click(view.root.querySelector('[data-composer-toolbar-cancel]'));

    expect(view.field.value).toEqual(saved);
    expect(view.root.dataset.dirty).toEqual('false');
    expect(view.rows()[0].querySelector('[data-placement]').value).toEqual('visible');
    view.cleanup();
  });

  it('asks before leaving with an unsaved draft and clears the flag on submit', () => {
    const view = mount();
    const confirm = jest.spyOn(window, 'confirm').mockReturnValue(false);
    const link = document.createElement('a');

    link.href = '/settings/preferences';
    document.body.appendChild(link);
    fireEvent.change(view.rows()[0].querySelector('[data-placement]'), { target: { value: 'menu' } });
    fireEvent.click(link);

    expect(confirm).toHaveBeenCalledWith('Leave without saving?');
    confirm.mockClear();
    fireEvent.submit(view.root.closest('form'));

    expect(confirm).not.toHaveBeenCalled();
    expect(view.root.dataset.dirty).toEqual('true');
    expect(view.root.dataset.submitting).toEqual('true');

    const saving = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(saving);
    expect(saving.defaultPrevented).toBe(false);

    const restored = new Event('pageshow');
    Object.defineProperty(restored, 'persisted', { value: true });
    window.dispatchEvent(restored);
    expect(view.root.dataset.submitting).toEqual('false');

    const leaving = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(leaving);
    expect(leaving.defaultPrevented).toBe(true);
    confirm.mockRestore();
    view.cleanup();
  });
});

import fs from 'fs';
import path from 'path';

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import {
  dumpComposerToolbar,
  moveComposerToolbarItem,
  normalizeComposerToolbar,
  postingAccountControlAvailable,
  targetIndexForPointer,
} from '../composer_toolbar';

describe('normalizeComposerToolbar', () => {
  it('returns the footer then menu order when nothing is saved', () => {
    expect(normalizeComposerToolbar(undefined)).toEqual([
      { id: 'posting_account', placement: 'visible' },
      { id: 'media', placement: 'visible' },
      { id: 'cw', placement: 'visible' },
      { id: 'language', placement: 'visible' },
      { id: 'datetime', placement: 'menu' },
      { id: 'searchability', placement: 'menu' },
      { id: 'poll', placement: 'menu' },
    ]);
    expect(normalizeComposerToolbar('')).toEqual(normalizeComposerToolbar(null));
    expect(normalizeComposerToolbar('not json')).toEqual(normalizeComposerToolbar(null));
  });

  it('keeps a partial document safe when ids or placements are unknown', () => {
    const items = normalizeComposerToolbar('v1|nope:visible|poll:visible|media:sideways|cw:hidden|cw:menu');

    expect(items.map(item => item.id)).toEqual([
      'poll', 'media', 'cw', 'posting_account', 'language', 'datetime', 'searchability',
    ]);
    expect(items.find(item => item.id === 'poll').placement).toEqual('visible');
    expect(items.find(item => item.id === 'media').placement).toEqual('visible');
    expect(items.find(item => item.id === 'cw').placement).toEqual('hidden');
  });

  it('reads an older json document and ignores extra fields', () => {
    const items = normalizeComposerToolbar(JSON.stringify({
      v: 1,
      items: [{ id: 'language', placement: 'hidden', extra: true }],
    }));

    expect(items[0]).toEqual({ id: 'language', placement: 'hidden' });
    expect(items).toHaveLength(7);
    expect(dumpComposerToolbar(items)).toEqual(`v1|${items.map(item => `${item.id}:${item.placement}`).join('|')}`);
  });
});

describe('targetIndexForPointer', () => {
  const rects = [
    { top: 0, height: 40 },
    { top: 40, height: 40 },
    { top: 80, height: 40 },
    { top: 120, height: 40 },
  ];

  it('stays put until the pointer crosses the next row midpoint', () => {
    expect(targetIndexForPointer(rects, 1, 70)).toEqual(1);
    expect(targetIndexForPointer(rects, 1, 101)).toEqual(2);
    expect(targetIndexForPointer(rects, 1, 10)).toEqual(0);
  });
});

describe('moveComposerToolbarItem', () => {
  const items = normalizeComposerToolbar(null);

  it('moves one row and leaves the original array unchanged', () => {
    const moved = moveComposerToolbarItem(items, 'language', 0);

    expect(moved.map(item => item.id)[0]).toEqual('language');
    expect(items.map(item => item.id)[0]).toEqual('posting_account');
    expect(moveComposerToolbarItem(items, 'media', 1)).toBe(items);
  });
});

describe('composer footer scrolling', () => {
  const scss = fs.readFileSync(path.join(__dirname, '../../../../styles/mastodon/components.scss'), 'utf8');
  const footer = scss.slice(scss.lastIndexOf('.compose-form__buttons-wrapper {'));

  it('scrolls the action row and keeps publish from shrinking away', () => {
    expect(footer).toContain('overflow-x: auto');
    expect(footer).toContain('flex: 0 0 auto');
    expect(footer).not.toMatch(/\.compose-form__buttons \{[^}]*overflow:\s*hidden/);
  });
});

describe('postingAccountControlAvailable', () => {
  const delegated = ImmutableList([
    ImmutableMap({ id: 'local:1', kind: 'local' }),
    ImmutableMap({ id: 'delegated:2', kind: 'delegated', authorization: 'revoked' }),
  ]);

  it('treats only a delegated identity as a configured link', () => {
    expect(postingAccountControlAvailable({
      catalog: ImmutableList([ImmutableMap({ id: 'local:1', kind: 'local' })]),
      status: 'ready',
      selectedId: 'local:1',
      canLink: true,
    })).toBe(false);
    expect(postingAccountControlAvailable({
      catalog: delegated,
      status: 'ready',
      selectedId: 'local:1',
      canLink: false,
    })).toBe(true);
    expect(postingAccountControlAvailable({
      catalog: ImmutableList(),
      status: 'loading',
      selectedId: 'local:1',
      canLink: true,
    })).toBe(false);
    expect(postingAccountControlAvailable({
      catalog: ImmutableList(),
      status: 'failed',
      selectedId: 'local:1',
      canLink: true,
    })).toBe(false);
    expect(postingAccountControlAvailable({
      catalog: delegated,
      status: 'failed',
      selectedId: 'local:1',
      canLink: true,
    })).toBe(true);
    expect(postingAccountControlAvailable({
      catalog: ImmutableList(),
      status: 'failed',
      selectedId: 'delegated:9',
      canLink: true,
    })).toBe(true);
    expect(postingAccountControlAvailable({
      catalog: ImmutableList(),
      status: 'failed',
      selectedId: 'delegated:9',
      canLink: false,
    })).toBe(false);
  });
});

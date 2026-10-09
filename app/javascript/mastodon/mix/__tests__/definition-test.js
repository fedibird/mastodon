import { addDraftSource, moveDraftSource, prepareMix, removeDraftSource } from '../definition';

const source = (type, extra = {}) => ({ type, params: {}, ...extra });

describe('mix definitions', () => {
  it('saves a versioned definition with 2 to 8 ordered sources and no fetched posts', () => {
    const prepared = prepareMix({
      title: '  Morning  ',
      sources: [
        source('home'),
        source('public', { params: { onlyMedia: true } }),
        { type: 'list', id: '4', title: 'Friends', statuses: [{ content: 'hidden' }], params: {} },
      ],
    }, { createId: () => 'mix-1' });

    expect(prepared.ok).toBe(true);
    expect(prepared.mix).toEqual({
      id: 'mix-1',
      version: 1,
      title: 'Morning',
      sources: [
        { type: 'home', params: {} },
        { type: 'public', params: { onlyMedia: true } },
        { type: 'list', id: '4', title: 'Friends', params: {} },
      ],
    });
    expect(JSON.stringify(prepared.mix)).not.toContain('hidden');
  });

  it('rejects empty, short, long, and duplicate source lists', () => {
    expect(prepareMix({ title: ' ', sources: [source('home'), source('public')] }).errors).toContain('title_blank');
    expect(prepareMix({ title: 'A', sources: [] }).errors).toEqual(['sources_too_few']);
    expect(prepareMix({ title: 'A', sources: [source('home')] }).errors).toContain('sources_too_few');
    expect(prepareMix({
      title: 'A',
      sources: [source('home'), source('home', { title: 'same home' })],
    }).errors).toContain('source_duplicate');
    expect(prepareMix({
      title: 'x'.repeat(101),
      sources: [source('home'), source('limited')],
    }).errors).toContain('title_too_long');

    const tooMany = [];

    for (let i = 0; i < 9; i += 1) {
      tooMany.push(source('account', { id: String(i + 1) }));
    }

    expect(prepareMix({ title: 'A', sources: tooMany }).errors).toContain('sources_too_many');
    expect(prepareMix({ title: 'A', version: 2, sources: [source('home'), source('public')] }).errors).toContain('version_unsupported');
  });

  it('allows the same source in more than one mix', () => {
    const sources = [source('home'), source('hashtag', { id: 'ruby', params: { any: ['web'] } })];
    const first = prepareMix({ title: 'One', sources }, { createId: () => 'mix-a' });
    const second = prepareMix({ title: 'Two', sources }, { createId: () => 'mix-b' });

    expect(first.ok).toBe(true);
    expect(second.ok).toBe(true);
    expect(first.mix.id).not.toBe(second.mix.id);
    expect(first.mix.sources).toEqual(second.mix.sources);
  });

  it('adds, removes, and reorders draft sources without accepting duplicates', () => {
    let draft = { title: 'Desk', sources: [] };
    draft = addDraftSource(draft, source('home')).draft;
    const added = addDraftSource(draft, source('public'));
    const duplicate = addDraftSource(added.draft, { type: 'home', title: 'again', params: {} });
    const moved = moveDraftSource(added.draft, 1, -1);
    const removed = removeDraftSource(moved, 0);

    expect(added.ok).toBe(true);
    expect(duplicate.ok).toBe(false);
    expect(duplicate.error).toBe('source_duplicate');
    expect(moved.sources.map(item => item.type)).toEqual(['public', 'home']);
    expect(removed.sources.map(item => item.type)).toEqual(['home']);
    expect(addDraftSource({ title: 'A', sources: [1, 2, 3, 4, 5, 6, 7, 8].map(id => source('account', { id: String(id) })) }, source('home')).error).toBe('sources_too_many');
  });
});

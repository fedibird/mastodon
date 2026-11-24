import { removePersonalCategoryItem } from '../emoji_actions/api';

describe('removePersonalCategoryItem', () => {
  const originalFetch = global.fetch;

  afterEach(() => {
    global.fetch = originalFetch;
  });

  it('sends one typed reference to the category items route', async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve({
        revision: 2,
        operation: { removed: true, category_id: 'fav/orites', item_ids: ['thumb'] },
        stock: { categories: [] },
      }),
    }));

    await removePersonalCategoryItem('fav/orites', {
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: 15,
      shortcode: 'wide_emoji',
    }, 4);

    expect(global.fetch).toHaveBeenCalledWith(
      '/api/v1/emoji_sets/personal/categories/fav%2Forites/items',
      expect.objectContaining({
        method: 'DELETE',
        body: JSON.stringify({
          expected_revision: 4,
          emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '15', shortcode: 'wide_emoji' },
        }),
      }),
    );
  });
});

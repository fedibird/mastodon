import { subscriptionMatchesStream } from '../stream';

describe('shared websocket delivery', () => {
  it('keeps tagged group feeds from receiving each other', () => {
    const plain = ['group', '9'];
    const news = ['group', '9', 'news'];
    const sports = ['group', '9', 'sports'];
    const otherGroup = ['group', '8', 'news'];
    const mediaNews = ['group:media', '9', 'news'];

    expect(subscriptionMatchesStream('group', { id: '9' }, plain)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, news)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, sports)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, plain)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'sports' }, sports)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'sports' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '8', tagged: 'news' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '8', tagged: 'news' }, otherGroup)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, mediaNews)).toBe(false);
    expect(subscriptionMatchesStream('group:media', { id: '9', tagged: 'news' }, mediaNews)).toBe(true);
  });
});

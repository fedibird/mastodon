export const getLinks = () => ({ refs: [] });
export default () => ({
  get: () => Promise.resolve({ data: [] }),
  post: (url, { status_ids }) => {
    window.fixturePosts.push({ ids: status_ids, at: performance.now() });
    return new Promise(resolve => setTimeout(() => resolve({ data: { matches: Object.fromEntries(status_ids.map(id => [id, window.fixtureMatches.includes(id) ? ['1'] : []])), unavailable: [] } }), 10));
  },
});

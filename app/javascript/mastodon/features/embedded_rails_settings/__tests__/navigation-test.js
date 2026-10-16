import { safeReactReturnTo, trackSettingsOrigin, settingsReturnScroll, settleSettingsReturnScroll } from '../navigation';

it('remembers observed React origins and retains them for Back/Forward', () => {
  const source = { pathname: '/timelines/tag/ruby', search: '?only_media=1', hash: '#position', key: 'source' };
  const settings = { pathname: '/settings/filters', key: 'settings' };
  const initial = { lastLocation: source, origins: {} };
  const state = trackSettingsOrigin(initial, settings, 'PUSH');
  expect(state.origins.settings).toBe('/timelines/tag/ruby?only_media=1#position');
  const back = trackSettingsOrigin(state, source, 'POP');
  expect(trackSettingsOrigin(back, settings, 'POP').origins.settings).toBe(state.origins.settings);
});

it('does not invent origins for direct access, replace, or an unobserved history entry', () => {
  const source = { pathname: '/timelines/home' };
  const settings = { pathname: '/settings/filters', key: 'settings' };
  const initial = { lastLocation: settings, origins: {} };
  expect(trackSettingsOrigin(initial, settings, 'POP')).toBeNull();
  expect(trackSettingsOrigin({ lastLocation: source, origins: {} }, settings, 'REPLACE').origins).toEqual({});
  expect(trackSettingsOrigin({ lastLocation: source, origins: {} }, settings, 'POP').origins).toEqual({});
});

it.each(['//evil.test/path', 'https://evil.test', '/\\evil.test', '/settings/filters', '/timelines/home\n'])('rejects unsafe or recursive return paths: %s', pathname => {
  expect(safeReactReturnTo({ pathname })).toBeNull();
});


it.each(['scrolled-source', undefined])('captures origin scroll including the initial browser entry (%s)', key => {
  const source = { pathname: '/timelines/tag/scroll', key };
  const settings = { pathname: '/settings/filters', key: 'scrolled-settings' };
  const oldY = window.scrollY;
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 300 });
  trackSettingsOrigin({ lastLocation: source, origins: {} }, settings, 'PUSH');
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 251 });
  expect(settingsReturnScroll(settings, source)).toEqual([0, 300]);
  expect(settingsReturnScroll(source, settings)).toBeUndefined();
  expect(settingsReturnScroll(settings, { key: 'direct-entry', pathname: '/timelines/home' })).toBeUndefined();
  expect(settingsReturnScroll(settings, { key, pathname: '/timelines/home' })).toBeUndefined();
  Object.defineProperty(window, 'scrollY', { configurable: true, value: oldY });
});


it.each([true, false])('settles scroll once after paint only if the source entry is still current (%s)', current => {
  const oldUrl = window.location.href;
  const oldState = window.history.state;
  window.history.replaceState({ key: current ? 'source' : 'other' }, '', '/web/timelines/home');
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(fn => frames.push(fn));
  const scroll = jest.spyOn(window, 'scrollTo').mockImplementation(() => {});
  const cancel = settleSettingsReturnScroll({ pathname: '/timelines/home', key: 'source' }, [0, 300]);
  expect(scroll).not.toHaveBeenCalled();
  frames.shift()(); frames.shift()();
  expect(scroll).toHaveBeenCalledTimes(current ? 1 : 0);
  expect(frames).toHaveLength(0);
  cancel();
  raf.mockRestore(); scroll.mockRestore();
  window.history.replaceState(oldState, '', oldUrl);
});


it('keeps the source post at its old offset while a temporary loading row is present', () => {
  const oldUrl = window.location.href;
  const oldState = window.history.state;
  const oldY = window.scrollY;
  window.history.replaceState({ key: 'anchor-source' }, '', '/web/timelines/home');
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 300 });
  const post = document.createElement('div'); post.className = 'status'; post.dataset.id = 'post1';
  const rect = jest.fn().mockReturnValue({ top: 100, bottom: 200, width: 500 });
  post.getBoundingClientRect = rect; document.body.appendChild(post);
  const source = { pathname: '/timelines/home', key: 'anchor-source' };
  trackSettingsOrigin({ lastLocation: source, origins: {} }, { pathname: '/settings/filters', key: 'anchor-settings' }, 'PUSH');
  rect.mockReturnValue({ top: 149, bottom: 249, width: 500 });
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(fn => frames.push(fn));
  const scroll = jest.spyOn(window, 'scrollTo').mockImplementation(() => {});
  const cancel = settleSettingsReturnScroll(source, [0, 300]);
  frames.shift()(); frames.shift()();
  expect(scroll).toHaveBeenCalledWith(0, 349);
  cancel();
  raf.mockRestore(); scroll.mockRestore(); post.remove();
  Object.defineProperty(window, 'scrollY', { configurable: true, value: oldY });
  window.history.replaceState(oldState, '', oldUrl);
});


it('corrects a late automatic scroll adjustment but stops when the user scrolls', () => {
  const oldUrl = window.location.href; const oldState = window.history.state; const oldY = window.scrollY;
  window.history.replaceState({ key: 'late-source' }, '', '/web/timelines/home');
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 300 });
  const source = { pathname: '/timelines/home', key: 'late-source' };
  trackSettingsOrigin({ lastLocation: source, origins: {} }, { pathname: '/settings/filters', key: 'late-settings' }, 'PUSH');
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(fn => frames.push(fn));
  const scroll = jest.spyOn(window, 'scrollTo').mockImplementation(() => {});
  const cancel = settleSettingsReturnScroll(source, [0, 300]); frames.shift()(); frames.shift()();
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 251 });
  window.dispatchEvent(new Event('scroll'));
  expect(scroll).toHaveBeenCalledWith(0, 300);
  scroll.mockClear(); window.dispatchEvent(new Event('wheel')); window.dispatchEvent(new Event('scroll'));
  expect(scroll).not.toHaveBeenCalled();
  cancel(); raf.mockRestore(); scroll.mockRestore();
  Object.defineProperty(window, 'scrollY', { configurable: true, value: oldY });
  window.history.replaceState(oldState, '', oldUrl);
});

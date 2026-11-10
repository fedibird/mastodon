/**
 * @jest-environment jsdom
 */

import { createMemoryHistory } from 'history';
import {
  MODAL_HISTORY_SETTLE_FALLBACK_MS,
  navigateAfterPickerClose,
} from '../emoji_actions/navigate_after_picker_close';

describe('navigateAfterPickerClose', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('pushes immediately (next task) when no mastodonModalKey is present', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    const pushSpy = jest.spyOn(history, 'push');

    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');

    expect(pushSpy).not.toHaveBeenCalled();
    jest.advanceTimersByTime(0);
    expect(pushSpy).toHaveBeenCalledTimes(1);
    expect(history.location.pathname).toBe('/emoji_detail/unicode/grinning');
  });

  it('waits for POP before pushing when a modal history key is present', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 42 });

    const pushSpy = jest.spyOn(history, 'push');
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');

    // A late POP must not arrive after an early push — we must not push yet.
    jest.advanceTimersByTime(0);
    expect(pushSpy).not.toHaveBeenCalled();

    history.goBack();
    expect(pushSpy).toHaveBeenCalledTimes(1);
    expect(history.location.pathname).toBe('/emoji_detail/unicode/grinning');
  });

  it('still pushes via fallback if POP never arrives', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 99 });

    const pushSpy = jest.spyOn(history, 'push');
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');

    jest.advanceTimersByTime(MODAL_HISTORY_SETTLE_FALLBACK_MS);
    expect(pushSpy).toHaveBeenCalledTimes(1);
  });

  it('pushes only once when POP and fallback both fire', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 7 });

    const pushSpy = jest.spyOn(history, 'push');
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');

    history.goBack();
    jest.advanceTimersByTime(MODAL_HISTORY_SETTLE_FALLBACK_MS);

    expect(pushSpy).toHaveBeenCalledTimes(1);
  });

  it('cancel prevents a later push', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 3 });

    const pushSpy = jest.spyOn(history, 'push');
    const cancel = navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');
    cancel();

    history.goBack();
    jest.advanceTimersByTime(MODAL_HISTORY_SETTLE_FALLBACK_MS);
    expect(pushSpy).not.toHaveBeenCalled();
  });
});

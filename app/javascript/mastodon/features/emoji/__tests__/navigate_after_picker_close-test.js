/**
 * @jest-environment jsdom
 */

import { createMemoryHistory } from 'history';
import { navigateAfterPickerClose } from '../emoji_actions/navigate_after_picker_close';

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

  it('waits for POP when goBack runs after arming (ModalRoot order)', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 42 });

    const pushSpy = jest.spyOn(history, 'push');
    // Arm before close — same order as the controller.
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');
    history.goBack();

    expect(pushSpy).toHaveBeenCalledTimes(1);
    expect(history.location.pathname).toBe('/emoji_detail/unicode/grinning');
  });

  it('does not push on a fixed timeout while a delayed POP is still pending', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 99 });

    const realGoBack = history.goBack.bind(history);
    let pendingPop = null;
    history.goBack = () => {
      pendingPop = () => {
        history.goBack = realGoBack;
        realGoBack();
      };
    };

    const pushSpy = jest.spyOn(history, 'push');
    // Arm while delayed goBack is already installed (wraps it).
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');

    // ModalRoot close invokes goBack (marks goBackSeen, schedules delayed POP).
    history.goBack();
    expect(typeof pendingPop).toBe('function');

    jest.advanceTimersByTime(0);
    expect(pushSpy).not.toHaveBeenCalled();

    // Far beyond the old 100ms fallback — still must not push before POP.
    jest.advanceTimersByTime(500);
    expect(pushSpy).not.toHaveBeenCalled();

    pendingPop();
    expect(pushSpy).toHaveBeenCalledTimes(1);
    expect(history.location.pathname).toBe('/emoji_detail/unicode/grinning');
  });

  it('pushes after flush when goBack was skipped (no POP expected)', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 7 });

    const pushSpy = jest.spyOn(history, 'push');
    navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');
    // ModalRoot skips goBack — never call it.

    jest.advanceTimersByTime(0);
    expect(pushSpy).toHaveBeenCalledTimes(1);
  });

  it('cancel prevents a later push from POP', () => {
    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    history.push('/timelines/home', { mastodonModalKey: 3 });

    const pushSpy = jest.spyOn(history, 'push');
    const cancel = navigateAfterPickerClose(history, '/emoji_detail/unicode/grinning');
    cancel();

    history.goBack();
    jest.advanceTimersByTime(0);
    expect(pushSpy).not.toHaveBeenCalled();
  });
});

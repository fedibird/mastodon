import { autoResumeDecision, resumeModeForWindow, routeResumeDecision, sameHostLayout } from '../policy';

const saved = (routeEntryKey = 'entry-a') => ({
  routeEntryKey,
  position: {
    anchor: { statusId: '100' },
  },
});

describe('timeline position restore policy', () => {
  it('does not apply a saved place on a new visit', () => {
    expect(routeResumeDecision({
      saved: saved(),
      locationKey: 'entry-b',
      historyAction: 'PUSH',
    })).toEqual({ apply: false, reason: 'new_visit' });
  });

  it('applies an explicit resume and a pop back to the same entry', () => {
    expect(routeResumeDecision({
      saved: saved(),
      locationKey: 'entry-b',
      historyAction: 'PUSH',
      explicit: true,
    }).reason).toBe('explicit');

    expect(routeResumeDecision({
      saved: saved(),
      locationKey: 'entry-a',
      historyAction: 'POP',
    })).toEqual({ apply: true, reason: 'route_pop' });
  });

  it('lets the split return anchor and a loaded row win over automatic resume', () => {
    expect(autoResumeDecision({
      saved: saved(),
      locationKey: 'entry-a',
      historyAction: 'POP',
      historyOpen: false,
    }).reason).toBe('history_closed');

    expect(autoResumeDecision({
      saved: saved(),
      locationKey: 'entry-a',
      historyAction: 'POP',
      historyOpen: true,
      returnAnchorOwnsRestore: true,
    }).reason).toBe('return_anchor');

    expect(autoResumeDecision({
      saved: saved(),
      locationKey: 'entry-a',
      historyAction: 'POP',
      historyOpen: true,
      statusInWindow: true,
    }).reason).toBe('loaded_row');

    expect(autoResumeDecision({
      saved: saved(),
      locationKey: 'entry-a',
      historyAction: 'POP',
      historyOpen: true,
    })).toEqual({ apply: true, reason: 'route_pop' });
  });

  it('scrolls inside the loaded window and seeks outside it', () => {
    expect(resumeModeForWindow({ statusId: '100', items: ['300', null, '100'] }).mode).toBe('scroll');
    expect(resumeModeForWindow({ statusId: '50', items: ['300', '100'] })).toEqual({ mode: 'seek', reason: 'outside_window' });
    expect(resumeModeForWindow({ statusId: 'nope', items: [] }).mode).toBe('unavailable');
    expect(sameHostLayout({ hostKind: 'history', layout: 'single' }, { hostKind: 'history', layout: 'columns' })).toBe(false);
    expect(sameHostLayout({ hostKind: 'history', layout: 'single' }, { hostKind: 'history', layout: 'single' })).toBe(true);
  });
});

import { classifyTimelinePage, walkTimelineForStatus } from '../reconcile';

describe('timeline reconcile coverage', () => {
  it('confirms only when the status id is in a fetched page', () => {
    expect(classifyTimelinePage('77', ['90', '77', '70'], false)).toBe('confirmed');
  });

  it('does not exclude a status that is older than the latest page', () => {
    const latest = Array.from({ length: 20 }, (_, index) => String(5000 - index));

    expect(classifyTimelinePage('77', latest, false)).toBe('continue');
    expect(walkTimelineForStatus('77', [
      { ids: latest },
      { ids: ['80', '77', '60'] },
    ]).outcome).toBe('confirmed');
  });

  it('excludes a status inside a covered span, including language and mute gaps', () => {
    expect(classifyTimelinePage('77', ['90', '70'], true)).toBe('excluded');
    expect(walkTimelineForStatus('77', [{ ids: ['90', '70'] }]).outcome).toBe('excluded');
  });

  it('treats a post newer than the whole feed as not yet verifiable', () => {
    expect(classifyTimelinePage('77', ['40'], true)).toBe('inconclusive');
    expect(classifyTimelinePage('77', [], true)).toBe('inconclusive');
    expect(walkTimelineForStatus('77', [{ ids: [] }]).outcome).toBe('inconclusive');
  });

  it('excludes a status when a full page is followed by an empty older page', () => {
    const latest = Array.from({ length: 20 }, (_, index) => String(5000 - index));

    expect(walkTimelineForStatus('77', [
      { ids: latest },
      { ids: [] },
    ]).outcome).toBe('excluded');
  });
});

import {
  TIMELINE_ANCHOR_REASONS,
  createTimelinePosition,
  decodeTimelineAnchor,
  encodeTimelineAnchor,
  sameTimelineSource,
  sameTimelineView,
  selectAnchorFromMeasurements,
  timelineAnchorDelta,
  timelineSourceIdentity,
  timelineViewIdentity,
} from '../anchor';

const row = (rowId, top, height) => ({ rowId, top, bottom: top + height, height });

describe('timeline anchor geometry', () => {
  it('keeps the row that straddles the visible top and stores a negative offset', () => {
    const selected = selectAnchorFromMeasurements({
      rows: [row('100', -80, 40), row('90', -20, 100), row('80', 90, 100)],
      visibleTop: 64,
      visibleHeight: 700,
      alignment: 'top',
    });

    expect(selected).toEqual({ rowId: '90', offsetPx: -84, alignment: 'top' });
    expect(timelineAnchorDelta({
      rowTop: -20,
      rowHeight: 100,
      visibleTop: 64,
      visibleHeight: 700,
      offsetPx: selected.offsetPx,
      alignment: 'top',
    })).toBe(0);
  });

  it('returns an empty anchor when the host has no rows or only gaps', () => {
    expect(selectAnchorFromMeasurements({ rows: [], visibleTop: 10 })).toEqual({
      rowId: null,
      offsetPx: 0,
      alignment: 'top',
    });
    expect(selectAnchorFromMeasurements({
      rows: [{ rowId: '', top: 0, bottom: 40, height: 40 }],
      visibleTop: 0,
    }).rowId).toBeNull();
  });

  it('centers a row against the viewport midline', () => {
    const selected = selectAnchorFromMeasurements({
      rows: [row('10', 0, 100), row('11', 100, 80)],
      visibleTop: 0,
      visibleHeight: 200,
      alignment: 'center',
    });

    expect(selected.rowId).toBe('11');
    expect(selected.alignment).toBe('center');
    expect(timelineAnchorDelta({
      rowTop: 100,
      rowHeight: 80,
      visibleTop: 0,
      visibleHeight: 200,
      offsetPx: 0,
      alignment: 'center',
    })).toBe(40);
  });
});

describe('timeline position contract', () => {
  const anchor = {
    version: 1,
    statusId: '12634567890123456789',
    offsetPx: -12.5,
    alignment: 'top',
    fallbackScrollTop: 480,
    capturedAt: '2026-10-17T03:31:02.000Z',
    accessToken: 'secret',
  };

  it('keeps snowflake ids as strings and drops unknown fields', () => {
    const encoded = encodeTimelineAnchor(anchor);

    expect(encoded.ok).toBe(true);
    expect(encoded.anchor.statusId).toBe('12634567890123456789');
    expect(typeof encoded.anchor.statusId).toBe('string');
    expect(JSON.parse(JSON.stringify(encoded.anchor)).statusId).toBe('12634567890123456789');
    expect(String(Number(anchor.statusId))).not.toBe(anchor.statusId);
    expect(encoded.anchor.accessToken).toBeUndefined();
    expect(Object.keys(encoded.anchor).sort()).toEqual([
      'alignment',
      'capturedAt',
      'fallbackScrollTop',
      'offsetPx',
      'statusId',
      'version',
    ]);
  });

  it('rejects numeric ids, bad versions, and non-finite offsets', () => {
    expect(decodeTimelineAnchor({ ...anchor, statusId: 12634567890123456789 }).reason).toBe(TIMELINE_ANCHOR_REASONS.INVALID);
    expect(decodeTimelineAnchor({ ...anchor, version: 2 }).ok).toBe(false);
    expect(decodeTimelineAnchor({ ...anchor, offsetPx: Number.NaN }).ok).toBe(false);
    expect(decodeTimelineAnchor({ ...anchor, alignment: 'bottom' }).ok).toBe(false);
    expect(decodeTimelineAnchor(null).ok).toBe(false);
  });

  it('treats source identity and view identity as separate', () => {
    const source = timelineSourceIdentity('list:42', { local: true });
    const otherConditions = timelineSourceIdentity('list:42', { local: false });
    const left = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'list:42:column-a',
      locationKey: 'route-a',
      pane: 'history',
      dataTimelineId: 'list:42:split:column-a:session',
    });
    const right = timelineViewIdentity({
      columnId: 'column-b',
      scrollKey: 'list:42:column-b',
      locationKey: 'route-a',
      pane: 'history',
      dataTimelineId: 'list:42:split:column-a:session',
    });

    expect(sameTimelineSource(source, timelineSourceIdentity('list:42', { local: true }))).toBe(true);
    expect(sameTimelineSource(source, otherConditions)).toBe(false);
    expect(sameTimelineSource(source, timelineSourceIdentity('home'))).toBe(false);
    expect(sameTimelineView(left, { ...left })).toBe(true);
    expect(sameTimelineView(left, right)).toBe(false);

    const position = createTimelinePosition({ source, view: left, anchor });
    const otherSurface = createTimelinePosition({ source, view: right, anchor });

    expect(position.ok).toBe(true);
    expect(otherSurface.ok).toBe(true);
    expect(position.position.source).toEqual(otherSurface.position.source);
    expect(sameTimelineView(position.position.view, otherSurface.position.view)).toBe(false);
    expect(position.position.anchor.accessToken).toBeUndefined();
    expect(createTimelinePosition({
      source,
      view: left,
      anchor: { ...anchor, token: 'do-not-keep', statusId: 15 },
    }).ok).toBe(false);
  });

  it('keeps hashtag tag lists and mix source lists distinct', () => {
    const bar = timelineSourceIdentity('hashtag:foo', { all: ['bar'], any: ['news'], none: [] });
    const baz = timelineSourceIdentity('hashtag:foo', { all: ['baz'], any: ['news'], none: [] });
    const reordered = timelineSourceIdentity('hashtag:foo', { none: [], any: ['news'], all: ['bar'] });
    const home = timelineSourceIdentity('mix:1', { sources: ['v1|home|-|-', 'v1|hashtag|ruby|all=bar'] });
    const otherMix = timelineSourceIdentity('mix:1', { sources: ['v1|home|-|-', 'v1|hashtag|ruby|all=baz'] });

    expect(bar.conditions.all).toEqual(['bar']);
    expect(sameTimelineSource(bar, baz)).toBe(false);
    expect(sameTimelineSource(bar, reordered)).toBe(true);
    expect(sameTimelineSource(home, otherMix)).toBe(false);
    expect(JSON.parse(JSON.stringify(home.conditions.sources))).toEqual([
      'v1|home|-|-',
      'v1|hashtag|ruby|all=bar',
    ]);
  });

  it('rejects conditions and view fields that cannot be stored without collapsing identity', () => {
    expect(timelineSourceIdentity('home', {
      local: true,
      password: { raw: 'nope' },
    })).toBeNull();
    expect(timelineSourceIdentity('home', { note: 'x'.repeat(300) })).toBeNull();
    expect(timelineSourceIdentity('home', { 'weird key': true })).toBeNull();
    expect(timelineSourceIdentity('x'.repeat(257))).toBeNull();
    expect(timelineViewIdentity({ columnId: 'x'.repeat(257) })).toBeNull();
    expect(timelineViewIdentity({ columnId: 15 })).toBeNull();
    expect(timelineViewIdentity({ scrollKey: { secret: true } })).toBeNull();

    const validView = timelineViewIdentity({ columnId: 'column-a' });
    const longSource = createTimelinePosition({
      source: { kind: 'timeline_source', sourceTimelineId: 'h'.repeat(257), conditions: null },
      view: validView,
      anchor,
    });
    const invalidView = createTimelinePosition({
      source: timelineSourceIdentity('hashtag:foo', { all: ['bar'] }),
      view: { kind: 'timeline_view', columnId: { id: 'hidden' } },
      anchor,
    });
    const tagged = createTimelinePosition({
      source: timelineSourceIdentity('hashtag:foo', { all: ['bar'] }),
      view: validView,
      anchor,
    });

    expect(longSource).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID });
    expect(invalidView).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID });
    expect(tagged.ok).toBe(true);
    expect(tagged.position.source.conditions).toEqual({ all: ['bar'] });
    expect(tagged.position.source).not.toBeNull();
    expect(tagged.position.view.columnId).toBe('column-a');
  });

  it('round-trips a featured display row separately from its status id', () => {
    const encoded = encodeTimelineAnchor({
      version: 1,
      statusId: '90',
      displayRowId: 'f-90',
      offsetPx: -4,
      alignment: 'top',
    });
    const conflict = decodeTimelineAnchor({
      version: 1,
      statusId: '91',
      displayRowId: 'f-90',
      offsetPx: 0,
      alignment: 'top',
    });
    const filled = decodeTimelineAnchor({
      version: 1,
      displayRowId: 'f-12634567890123456789',
      offsetPx: 1,
      alignment: 'center',
    });

    expect(encoded.ok).toBe(true);
    expect(encoded.anchor.statusId).toBe('90');
    expect(encoded.anchor.displayRowId).toBe('f-90');
    expect(JSON.parse(JSON.stringify(encoded.anchor)).displayRowId).toBe('f-90');
    expect(conflict.ok).toBe(false);
    expect(filled.anchor.statusId).toBe('12634567890123456789');
    expect(filled.anchor.displayRowId).toBe('f-12634567890123456789');
    expect(String(Number(filled.anchor.statusId))).not.toBe(filled.anchor.statusId);
    expect(decodeTimelineAnchor({
      version: 1,
      statusId: '91',
      displayRowId: 'some-other-row',
      offsetPx: 0,
      alignment: 'top',
    }).ok).toBe(false);
    expect(decodeTimelineAnchor({
      version: 1,
      displayRowId: 'some-other-row',
      offsetPx: 0,
      alignment: 'top',
    }).anchor).toEqual({
      version: 1,
      statusId: null,
      displayRowId: 'some-other-row',
      offsetPx: 0,
      alignment: 'top',
    });
  });

  it('rejects prototype keys that would collapse different conditions', () => {
    const alpha = timelineSourceIdentity('home', JSON.parse('{"__proto__":["alpha"]}'));
    const beta = timelineSourceIdentity('home', JSON.parse('{"__proto__":["beta"]}'));
    const constructorKey = timelineSourceIdentity('home', { constructor: ['nope'] });
    const kept = timelineSourceIdentity('hashtag:foo', { all: ['bar'] });

    expect(alpha).toBeNull();
    expect(beta).toBeNull();
    expect(sameTimelineSource(alpha, beta)).toBe(false);
    expect(constructorKey).toBeNull();
    expect(kept.conditions.all).toEqual(['bar']);
    expect(JSON.parse(JSON.stringify(kept.conditions)).all).toEqual(['bar']);
  });

  it('matches history again after it is closed and opened on the same column', () => {
    const opened = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'home_timeline-column-a',
      locationKey: 'nav-1',
      pane: 'history',
      dataTimelineId: 'home:split:column-a:session-1',
    });
    const reopened = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'home_timeline-column-a',
      locationKey: 'nav-2',
      pane: 'history',
      dataTimelineId: 'home:split:column-a:session-2',
    });
    const otherColumn = timelineViewIdentity({
      columnId: 'column-b',
      scrollKey: 'home_timeline-column-b',
      locationKey: 'nav-2',
      pane: 'history',
      dataTimelineId: 'home:split:column-b:session-2',
    });
    const live = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'home_timeline-column-a-live',
      locationKey: 'nav-2',
      pane: 'live',
      dataTimelineId: 'home',
    });
    const listOpened = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'list_timeline-column-a',
      pane: 'history',
      dataTimelineId: 'list:42:split:column-a:session-1',
    });
    const listReopened = timelineViewIdentity({
      columnId: 'column-a',
      scrollKey: 'list_timeline-column-a',
      locationKey: 'nav-9',
      pane: 'history',
      dataTimelineId: 'list:42:split:column-a:session-9',
    });

    expect(opened.dataTimelineId).toBe('home:split:column-a');
    expect(opened.sessionId).toBe('session-1');
    expect(opened.locationKey).toBe('nav-1');
    expect(reopened.sessionId).toBe('session-2');
    expect(reopened.locationKey).toBe('nav-2');
    expect(sameTimelineView(opened, reopened)).toBe(true);
    expect(sameTimelineView(opened, otherColumn)).toBe(false);
    expect(sameTimelineView(opened, live)).toBe(false);
    expect(listOpened.dataTimelineId).toBe('list:42:split:column-a');
    expect(sameTimelineView(listOpened, listReopened)).toBe(true);
    expect(timelineViewIdentity({
      columnId: 'column-a',
      dataTimelineId: 'home:split:column-a:session-1',
      sessionId: 'session-2',
    })).toBeNull();

    const saved = createTimelinePosition({
      source: timelineSourceIdentity('home'),
      view: opened,
      anchor,
    });
    const again = createTimelinePosition({
      source: timelineSourceIdentity('home'),
      view: reopened,
      anchor,
    });

    expect(saved.ok).toBe(true);
    expect(saved.position.view.sessionId).toBe('session-1');
    expect(sameTimelineView(saved.position.view, again.position.view)).toBe(true);
    expect(saved.position.view.sessionId).not.toBe(again.position.view.sessionId);
  });
});

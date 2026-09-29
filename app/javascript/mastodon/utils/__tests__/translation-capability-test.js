import { fromJS } from 'immutable';

import { selfAuthoredPersonalStatus, translationCapability } from '../translation_languages';

const languages = fromJS({
  en: ['ja'],
});

const status = (overrides = {}) => fromJS({
  id: 's1',
  search_index: 'Hello',
  visibility: 'personal',
  account: { id: '1' },
  ...overrides,
});

const capability = (record, options = {}) => translationCapability(record, { source: 'en', target: 'ja' }, languages, {
  loggedIn: true,
  privateContentAllowed: false,
  viewerAccountId: '1',
  ...options,
});

describe('selfAuthoredPersonalStatus', () => {
  it('allows a personal original and a personal boost only when both authors are the viewer', () => {
    expect(selfAuthoredPersonalStatus(status(), '1')).toBe(true);
    expect(selfAuthoredPersonalStatus(status({ account: { id: 1 } }), 1)).toBe(true);
    expect(selfAuthoredPersonalStatus(status({
      reblog: { account: { id: '1' } },
    }), '1')).toBe(true);

    expect(selfAuthoredPersonalStatus(status({ account: { id: '2' } }), '1')).toBe(false);
    expect(selfAuthoredPersonalStatus(status({
      reblog: { account: { id: '9' } },
    }), '1')).toBe(false);
    expect(selfAuthoredPersonalStatus(status(), null)).toBe(false);
    expect(selfAuthoredPersonalStatus(status({ visibility: 'private' }), '1')).toBe(false);
  });
});

describe('translationCapability personal visibility', () => {
  it('enables a self-authored personal status without provider-wide private content', () => {
    expect(capability(status())).toEqual({
      allowsRequest: true,
      languagesKnown: true,
      pairSupported: true,
    });
  });

  it('keeps someone else personal content, private visibilities, logged-out, and empty content disabled', () => {
    expect(capability(status({ account: { id: '2' } })).allowsRequest).toBe(false);
    expect(capability(status({ reblog: { account: { id: '9' } } })).allowsRequest).toBe(false);
    ['private', 'direct', 'limited', 'mutual'].forEach(visibility => {
      expect(capability(status({ visibility })).allowsRequest).toBe(false);
    });
    expect(capability(status(), { loggedIn: false, viewerAccountId: null }).allowsRequest).toBe(false);
    expect(capability(status({ search_index: '   ' })).allowsRequest).toBe(false);
    expect(capability(status(), { viewerAccountId: '1' }).pairSupported).toBe(true);
    expect(translationCapability(status(), { source: 'fr', target: 'de' }, languages, {
      loggedIn: true,
      privateContentAllowed: false,
      viewerAccountId: '1',
    }).pairSupported).toBe(false);
  });

  it('still allows every visibility when the provider allows private content', () => {
    ['public', 'unlisted', 'private', 'direct', 'limited', 'mutual', 'personal'].forEach(visibility => {
      expect(capability(status({
        visibility,
        account: { id: '2' },
      }), { privateContentAllowed: true }).allowsRequest).toBe(true);
    });
  });
});

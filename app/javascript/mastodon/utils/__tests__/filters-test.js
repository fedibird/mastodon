import { toServerSideType } from '../filters';

describe('toServerSideType', () => {
  it('keeps canonical contexts', () => {
    expect(['home', 'notifications', 'public', 'thread', 'account'].map(toServerSideType))
      .toEqual(['home', 'notifications', 'public', 'thread', 'account']);
  });

  it('maps list columns to home', () => {
    expect(toServerSideType('list:12')).toEqual('home');
  });

  it('maps Fedibird public-like timelines to public', () => {
    expect(toServerSideType('community')).toEqual('public');
    expect(toServerSideType('domain')).toEqual('public');
    expect(toServerSideType('domain:example.com')).toEqual('public');
    expect(toServerSideType('group:12')).toEqual('public');
    expect(toServerSideType('hashtag:foo')).toEqual('public');
    expect(toServerSideType('public:remote')).toEqual('public');
    expect(toServerSideType('public:remote:bot')).toEqual('public');
  });

  it('maps Fedibird limited/personal/direct columns to public', () => {
    // Server Filter contexts have no limited/personal/direct value.
    // Unknown columns inherit public, matching Mastodon 4.2.
    expect(toServerSideType('limited')).toEqual('public');
    expect(toServerSideType('personal')).toEqual('public');
    expect(toServerSideType('direct')).toEqual('public');
    expect(toServerSideType(undefined)).toEqual('public');
  });
});

import { toServerSideType } from '../filters';

describe('toServerSideType', () => {
  it('keeps canonical contexts', () => {
    expect(['home', 'notifications', 'public', 'thread', 'account'].map(toServerSideType))
      .toEqual(['home', 'notifications', 'public', 'thread', 'account']);
  });

  it('maps list columns to home', () => {
    expect(toServerSideType('list:12')).toEqual('home');
  });

  it('maps unknown columns to public', () => {
    expect(toServerSideType('community')).toEqual('public');
    expect(toServerSideType(undefined)).toEqual('public');
  });
});

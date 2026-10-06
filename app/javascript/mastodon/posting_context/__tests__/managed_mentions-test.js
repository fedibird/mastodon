import { materializeManagedMentions, textContainsMention } from '../managed_mentions';

describe('managed mentions', () => {
  it('prefixes a missing required mention and leaves an existing one', () => {
    expect(materializeManagedMentions('Hello', [{ acct: 'group' }])).toEqual('@group Hello');
    expect(materializeManagedMentions('', [{ acct: 'group' }])).toEqual('@group');
    expect(materializeManagedMentions('Hello @group', [{ acct: 'group' }])).toEqual('Hello @group');
    expect(materializeManagedMentions('Hello @GROUP', [{ acct: 'group' }])).toEqual('Hello @GROUP');
  });

  it('treats a remote acct as exact and can prefix several mentions', () => {
    expect(materializeManagedMentions('@group', [{ acct: 'group@example.com' }])).toEqual('@group@example.com @group');
    expect(materializeManagedMentions('@group@example.com Hello', [{ acct: 'group@example.com' }])).toEqual('@group@example.com Hello');
    expect(materializeManagedMentions('Hello', [{ acct: 'a' }, { acct: 'b' }])).toEqual('@a @b Hello');
  });

  it('matches mention boundaries from Account::MENTION_RE', () => {
    expect(textContainsMention('(@group)', 'group')).toBe(true);
    expect(textContainsMention('hello @group', 'group')).toBe(true);
    expect(textContainsMention('word@group', 'group')).toBe(false);
    expect(textContainsMention('https://example/@group', 'group')).toBe(false);
    expect(textContainsMention('＠group', 'group')).toBe(false);
  });
});

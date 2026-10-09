import { firstLineLacksProse, materializeManagedMentions, textContainsMention } from '../managed_mentions';

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

  it('appends a missing mention without changing the first line or duplicating one already written', () => {
    const mention = { acct: 'technology@lemmy.example', placement: 'append' };

    expect(materializeManagedMentions('Title line\n\nBody', [mention])).toEqual('Title line\n\nBody\n@technology@lemmy.example');
    expect(materializeManagedMentions('Title line\n\n', [mention])).toEqual('Title line\n\n@technology@lemmy.example');
    expect(materializeManagedMentions('', [mention])).toEqual('@technology@lemmy.example');
    expect(materializeManagedMentions('Title line\n@technology@lemmy.example', [mention])).toEqual('Title line\n@technology@lemmy.example');
    expect(materializeManagedMentions('@bob@people.example hello', [mention])).toEqual('@bob@people.example hello\n@technology@lemmy.example');
    expect(materializeManagedMentions('Hello', [
      { acct: 'technology@lemmy.example', placement: 'append' },
      { acct: 'other@lemmy.example', placement: 'append' },
    ])).toEqual('Hello\n@technology@lemmy.example @other@lemmy.example');
    expect(materializeManagedMentions('Hello', [
      { acct: 'group' },
      { acct: 'technology@lemmy.example', placement: 'append' },
    ])).toEqual('@group Hello\n@technology@lemmy.example');
  });

  it('inserts an after_title mention after the first line without rewriting the draft', () => {
    const mention = { acct: 'technology@lemmy.example', placement: 'after_title' };

    expect(materializeManagedMentions('', [mention])).toEqual('@technology@lemmy.example');
    expect(materializeManagedMentions('My title', [mention])).toEqual('My title\n@technology@lemmy.example');
    expect(materializeManagedMentions('My title\n', [mention])).toEqual('My title\n@technology@lemmy.example');
    expect(materializeManagedMentions('Title line\n\nKeep this @bob@people.example', [mention])).toEqual('Title line\n@technology@lemmy.example\n\nKeep this @bob@people.example');
    expect(materializeManagedMentions('Title\n\n\nHello @bob@people.example', [mention])).toEqual('Title\n@technology@lemmy.example\n\n\nHello @bob@people.example');
    expect(materializeManagedMentions('Title line\n@technology@lemmy.example\n\nKeep this', [mention])).toEqual('Title line\n@technology@lemmy.example\n\nKeep this');
    expect(materializeManagedMentions('Title @technology@lemmy.example\n\nKeep this @bob@people.example', [mention])).toEqual('Title @technology@lemmy.example\n\nKeep this @bob@people.example');
    expect(materializeManagedMentions('@bob@people.example stays\n\nsecond line', [mention])).toEqual('@bob@people.example stays\n@technology@lemmy.example\n\nsecond line');
    expect(materializeManagedMentions('Title\n\n\n', [mention])).toEqual('Title\n@technology@lemmy.example\n\n\n');
    expect(materializeManagedMentions('Hello', [
      { acct: 'technology@lemmy.example', placement: 'after_title' },
      { acct: 'other@lemmy.example', placement: 'after_title' },
    ])).toEqual('Hello\n@technology@lemmy.example @other@lemmy.example');
    expect(materializeManagedMentions('Hello', [
      { acct: 'group' },
      { acct: 'technology@lemmy.example', placement: 'after_title' },
      { acct: 'tail@piefed.example', placement: 'append' },
    ])).toEqual('@group Hello\n@technology@lemmy.example\n@tail@piefed.example');
  });

  it('treats an empty first line as a weak Lemmy title', () => {
    expect(firstLineLacksProse('')).toBe(true);
    expect(firstLineLacksProse('\nKeep this body')).toBe(true);
    expect(firstLineLacksProse('   \nKeep this body')).toBe(true);
    expect(firstLineLacksProse('@technology@lemmy.example\nBody')).toBe(true);
    expect(firstLineLacksProse('#only\nBody')).toBe(true);
    expect(firstLineLacksProse('Title line\n@technology@lemmy.example\n\nBody')).toBe(false);
  });
});

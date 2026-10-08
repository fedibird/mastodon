import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import { materializeComposerText } from '../materialize';

const composerWith = (text, { id = null, scheduledStatusId = null } = {}) => ImmutableMap({
  text,
  id,
  scheduled_status_id: scheduledStatusId,
  context: ImmutableMap({
    managed: ImmutableMap({
      hashtags: ImmutableList([
        ImmutableMap({ name: 'foo', normalizedName: 'foo', enforcement: 'advisory' }),
      ]),
      mentions: ImmutableList([
        ImmutableMap({ accountId: '123', acct: 'group', enforcement: 'required' }),
      ]),
    }),
    suppressions: ImmutableMap({
      hashtags: ImmutableSet(),
    }),
  }),
});

describe('materializeComposerText', () => {
  it('places required mentions before the draft and advisory hashtags after it', () => {
    expect(materializeComposerText(composerWith('Hello'))).toEqual('@group Hello\n\n#foo');
  });

  it('returns raw text while editing an existing or scheduled status', () => {
    expect(materializeComposerText(composerWith('Hello', { id: 'status-1' }))).toEqual('Hello');
    expect(materializeComposerText(composerWith('Hello', { scheduledStatusId: 'sched-1' }))).toEqual('Hello');
  });

  it('keeps a required tag when its name is suppressed and suppresses advisory origins separately', () => {
    const composer = composerWith('Hello').withMutations(map => {
      map.setIn(['context', 'managed', 'hashtags'], ImmutableList([
        ImmutableMap({ name: 'foo', normalizedName: 'foo', enforcement: 'required' }),
        ImmutableMap({ name: 'bar', normalizedName: 'bar', enforcement: 'advisory' }),
      ]));
      map.setIn(['context', 'suppressions', 'hashtags'], ImmutableSet(['foo', 'bar']));
      map.setIn(['userPostingStyle', 'selectedId'], '1');
      map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
      map.setIn(['userPostingStyle', 'suppressions'], ImmutableSet(['style:books']));
      map.setIn(['userPostingStyle', 'snapshot'], ImmutableMap({
        target: ImmutableMap({ kind: 'hashtag', hashtag: 'fedibird' }),
        managed: ImmutableMap({
          hashtags: ImmutableList([
            ImmutableMap({ name: 'books', normalizedName: 'books', enforcement: 'advisory' }),
            ImmutableMap({ name: 'foo', normalizedName: 'foo', enforcement: 'advisory' }),
          ]),
        }),
      }));
    });

    expect(materializeComposerText(composer)).toEqual('@group Hello\n\n#foo #fedibird');
  });
});

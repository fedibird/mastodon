import { connect } from 'react-redux';
import { List as ImmutableList } from 'immutable';
import { withComposerId } from '../composer_id_context';
import { selectComposer } from '../../../selectors/composer';
import { composerDraftHasPersistableInput, draftCaptureBlock } from '../../../drafts/snapshot';
import { restoreLocalComposerDraft } from '../../../drafts/restore';
import ComposerDraftRecovery from '../components/composer_draft_recovery';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const recovery = state.get('composerDraftRecovery');
  const offers = recovery ? recovery.get('offers', ImmutableList()) : ImmutableList();
  const persistence = recovery ? recovery.getIn(['persistence', composerId]) : null;
  const busy = !composer || composerDraftHasPersistableInput(composer) || Boolean(draftCaptureBlock(composer));
  const newest = !busy && offers.size > 0 ? offers.first() : null;

  return {
    offerId: newest ? newest.get('client_draft_uuid') : null,
    offerCount: busy ? 0 : offers.size,
    status: persistence ? persistence.get('status') : null,
    reason: persistence ? persistence.get('reason') : null,
    mediaIncomplete: persistence ? persistence.get('mediaIncomplete') === true : false,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onRestore (clientDraftUuid) {
    dispatch(restoreLocalComposerDraft(composerId, clientDraftUuid));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(ComposerDraftRecovery));

import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import { COMPOSER_DRAFT_STATUS } from '../actions/composer';

const initialState = ImmutableMap({
  offers: ImmutableList(),
  persistence: ImmutableMap(),
});

export default function composerDraftRecovery (state = initialState, action) {
  if (!action || action.type !== COMPOSER_DRAFT_STATUS || !action.view) {
    return state;
  }

  return ImmutableMap({
    offers: fromJS(action.view.offers || []),
    persistence: fromJS(action.view.persistence || {}),
  });
}

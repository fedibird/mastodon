import { combineReducers } from 'redux-immutable';
import dropdown_menu from './dropdown_menu';
import timelines from './timelines';
import immediate_feed from './immediate_feed';
import meta from './meta';
import alerts from './alerts';
import { loadingBarReducer } from 'react-redux-loading-bar';
import modal from './modal';
import user_lists from './user_lists';
import domain_lists from './domain_lists';
import accounts from './accounts';
import accounts_counters from './accounts_counters';
import statuses from './statuses';
import translation_assumptions from './translation_assumptions';
import translation_bar_overrides from './translation_bar_overrides';
import scheduled_statuses from './scheduled_statuses';
import processing_statuses from './processing_statuses';
import intersection_statuses from './intersection_statuses';
import relationships from './relationships';
import account_notifications from './account_notifications';
import settings from './settings';
import user_preferences from './user_preferences';
import push_notifications from './push_notifications';
import status_lists from './status_lists';
import emoji_reactioned_statuses from './emoji_reactioned_statuses';
import mutes from './mutes';
import blocks from './blocks';
import boosts from './boosts';
import reports from './reports';
import contexts from './contexts';
import posting_contexts from './posting_contexts';
import posting_context_revalidations from './posting_context_revalidations';
import user_posting_styles from './user_posting_styles';
import user_posting_context_assignments from './user_posting_context_assignments';
import posting_identities from './posting_identities';
import compose from './compose';
import composers from './composers';
import history from './history';
import search from './search';
import media_attachments from './media_attachments';
import notifications from './notifications';
import height_cache from './height_cache';
import custom_emojis from './custom_emojis';
import custom_emojis_detail from './custom_emojis_detail';
import lists from './lists';
import mix_timelines from './mix_timelines';
import listEditor from './list_editor';
import listAdder from './list_adder';
import circles from './circles';
import circleEditor from './circle_editor';
import circleAdder from './circle_adder';
import filters from './filters';
import filterMatches from './filter_matches';
import { maintainFilterMatchContent } from './filter_match_lifecycle';
import { FILTERS_IMPORT } from '../actions/importer';
import conversations from './conversations';
import suggestions from './suggestions';
import polls from './polls';
import identity_proofs from './identity_proofs';
import trends from './trends';
import missed_updates from './missed_updates';
import announcements from './announcements';
import markers from './markers';
import picture_in_picture from './picture_in_picture';
import favourite_domains from './favourite_domains';
import favourite_tags from './favourite_tags';
import tags from './tags';
import server from './server';
import accountContextViews from './account_context_views';

const reducers = {
  announcements,
  dropdown_menu,
  timelines,
  immediate_feed,
  meta,
  alerts,
  loadingBar: loadingBarReducer,
  modal,
  user_lists,
  domain_lists,
  status_lists,
  emoji_reactioned_statuses,
  accounts,
  accounts_counters,
  statuses,
  translation_assumptions,
  translation_bar_overrides,
  scheduled_statuses,
  processing_statuses,
  intersection_statuses,
  relationships,
  account_notifications,
  settings,
  user_preferences,
  push_notifications,
  mutes,
  blocks,
  boosts,
  reports,
  contexts,
  posting_contexts,
  posting_context_revalidations,
  userPostingStyles: user_posting_styles,
  userPostingContextAssignments: user_posting_context_assignments,
  postingIdentities: posting_identities,
  compose,
  composers,
  history,
  search,
  media_attachments,
  notifications,
  height_cache,
  custom_emojis,
  custom_emojis_detail,
  identity_proofs,
  lists,
  mix_timelines,
  listEditor,
  listAdder,
  circles,
  circleEditor,
  circleAdder,
  filters,
  filterMatches,
  conversations,
  suggestions,
  polls,
  trends,
  missed_updates,
  markers,
  picture_in_picture,
  favourite_domains,
  favourite_tags,
  tags,
  server,
  accountContextViews,
};

const combined = combineReducers(reducers);

export default (state, action) => {
  // Status payload FilterResults have neither complete rules nor a version.
  // After the first authoritative GET, they cannot resurrect deleted filters
  // or roll current action/title/context back. Explicit create success remains
  // available to the filter creation modal.
  const accepted = action.type === FILTERS_IMPORT && state?.getIn(['filterMatches', 'baseline']) ? { ...action, filters: [] } : action;
  return maintainFilterMatchContent(state, combined(state, accepted), action);
};

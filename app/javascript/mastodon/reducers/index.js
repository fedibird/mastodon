import { combineReducers } from 'redux-immutable';
import dropdown_menu from './dropdown_menu';
import timelines from './timelines';
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
import settings from './settings';
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
import listEditor from './list_editor';
import listAdder from './list_adder';
import circles from './circles';
import circleEditor from './circle_editor';
import circleAdder from './circle_adder';
import filters from './filters';
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

const reducers = {
  announcements,
  dropdown_menu,
  timelines,
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
  settings,
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
  listEditor,
  listAdder,
  circles,
  circleEditor,
  circleAdder,
  filters,
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
};

export default combineReducers(reducers);

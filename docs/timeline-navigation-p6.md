# P6: Timeline Navigation 統合検証

親 #487、仕様 #518。P0 #489、P1 #498、P2 #500、P3 #502、P4a #504、P4b-1 #506、P4b-2 #513、P5a #515、P5b #517 は `origin/fedibird` に入っている。この文書は機能追加の仕様ではなく、操作 × source × レイアウト × 中断条件のテストマトリクスである。

状態は次の三種類だけを使う。

- **実行済み**: この環境の Jest または RSpec で通した。既存のテストも、今回の実行に含めたものは実行済みとする。
- **今回追加**: P6 で足したテスト。実行結果は PR のテスト節を見る。
- **未実施**: 自動化していない、またはこの環境では実行できない。ブラウザ操作は、ログイン済みの実 Chrome で見ていない限り確認済みとは書かない。

## 今回直した不具合

コントローラが P3 / P4 / P5 を同時に走らせていた。

- 日付・アカウント・投稿 ID・本文検索のジャンプは、進行中の History resume を `reason: seek` で取り消してから、そのカラムの History だけを seek する。無効な投稿 ID、`splitBlocked`、他カラムが split を所有しているときは resume を取り消さない。
- 明示的な再開は、未確定のジャンプを一度だけ戻してから resume する。再開ボタンが無効な進行中 resume には割り込まない。
- History を開く直前の再開予約は、その前にジャンプまたはしおり復帰が始まったら実行しない。予約中のしおり復帰は resume 側を優先し、seek しない。
- ジャンプの seek が返る前のスクロールは `user_scroll` として記録し、その後の filtered settle では window を戻さない。
- カラム id が変わった未確定ジャンプは一度だけ戻し、その後の settle では戻さない。

Live の timeline id、Portable Composer の本文、検索語は seek payload に載らない。この修正は reducer の resume 契約を変えていない。

## 実行結果

Node 22.14.0。Jest は `yarn --ignore-engines jest --coverage=false --watchman=false`。

- 変更に隣接する 19 suites / 120 tests、失敗 0。内訳は exclusion、jump、text search、jump scroll、bookmark restore、resume button、split controller、text jump、bookmark panel、history resume DOM、reading bookmark の place / restore / contract / api、timeline position の registry / reduce / policy、jump model / scroll wait。実行できない日付ジャンプと本文結果ジャンプは、`splitBlocked` と他カラムの split 所有中に進行中 resume と再開予約を残す。
- ESLint は変更した JavaScript。新規の error はなし。`timeline_column_jump.js` の `jsx-a11y/no-onchange` は既存の select に対する warning。
- RSpec は `DB_NAME=mastodon_development RAILS_ENV=test bundle exec rspec spec/controllers/api/v1/fedibird/reading_bookmarks_controller_spec.rb spec/controllers/api/v1/timelines/seek_controller_spec.rb`。25 examples、失敗 0。

実 Chrome は未実施。

## 環境

- 実 Chrome での単一カラム、複数カラム、狭幅、テーマ、キーボード操作は **未実施**。手順は末尾。
- Jest は jsdom。レイアウト、sticky header、実画像の高さ、IME のネイティブ確定は再現しない。IME は `compositionstart` / `compositionend` / keyCode 229 のイベントだけを見る。
- RSpec はコントローラと、既存の TimelineSeek service spec。Redis の実保持範囲は既存の membership spec が担う。

## 1. source / context / 認可 / 所属

| 操作 | source | 確認 | 状態 | 置き場所 |
| --- | --- | --- | --- | --- |
| seek status | public | id を文字列で返し、direct 本文を出さない | 実行済み | `seek_controller_spec` |
| seek status / date / account | list | 他人のリストは 404、本文を出さない | 実行済み | `seek_controller_spec` |
| seek status | group | ユーザーアカウントを group にしない | 実行済み | `seek_controller_spec` |
| seek | home | 未ログインは 422 | 実行済み | `seek_controller_spec` |
| seek | personal | 他人の投稿は `not_in_source`、本文を出さない | 今回追加 | `seek_controller_spec` |
| seek | domain | 未知ドメインは `domain_unavailable`、本文を出さない | 今回追加 | `seek_controller_spec` |
| seek target | public | 検索語を拒否し、応答に含めない | 実行済み | `seek_controller_spec` |
| membership | public / home / list / hashtag / domain / group / personal / limited | 所属、フィルター、ブロック、権限変更、Redis 範囲、50 件 | 実行済み | `membership_spec`、`memberships_controller_spec` |
| しおり create | home | 本文・window・検索語を保存しない | 実行済み | `reading_bookmarks_controller_spec` |
| しおり create | list / group | 他人のリスト、リモート group、source id の不一致 | 実行済み | 同 |
| しおり create | limited / public / hashtag / domain / personal | context の許可キーだけを保存する | 今回追加 | 同 |
| しおり create | domain | `local: true` を拒否 | 今回追加 | 同 |
| しおり create | home | context の token を保存せず、応答にも出さない | 今回追加 | 同 |
| しおり create | home | ブロックした投稿者のアンカーは `not_found`、本文を出さない | 今回追加 | 同 |
| しおり create | home | `read:statuses` だけでは 403 | 今回追加 | 同 |
| しおり | list | `write:lists` がなければ create / update / destroy しない | 実行済み | 同 |
| しおり | list / group | 削除済みリストは missing、ブロックした group は not_accessible、名前を出さない | 実行済み | 同 |
| しおり | 全 source | 409、50 件、同名、OAuth の所有者境界 | 実行済み | 同 |
| クライアント契約 | 全 source | 検索語・window・本文を送らない | 実行済み | `reading_bookmarks/contract-test`、`place-test` |
| capability | 全 windowed source | 閉じた source と retention 2000 | 実行済み | `timeline_seek/model-test`、capabilities example |

Redis の範囲外を「存在しない」と断定しないことは membership spec と bookmark restore の `outside_retained_range` が実行済み。削除・フィルター・権限変更の HTTP 網羅は public / home / group が中心で、hashtag のキーワードフィルターまでコントローラでは見ていない。service spec 側は実行済み。

## 2. Live / History / window / seek 精度

| 操作 | レイアウト | 確認 | 状態 | 置き場所 |
| --- | --- | --- | --- | --- |
| 分割 / 解除 | 単一・複数 | スクロール位置、return anchor、partial では分割しない | 実行済み | `status_timeline_split_controller-test` |
| Live を残す / History を残す | 単一 | 閉じた側の scroll を取り違えない | 実行済み | 同、`history_resume_dom-test` |
| bounded window | — | アンカーから遠い側を削る、境界を超えない、stale generation | 実行済み | `windowed_history/model-test` |
| seek | home ほか | 厳密 / 近傍 / 不確定、検索語を落とす、巨大 id | 実行済み | `timeline_seek/model-test`、`resolver_spec` |
| P3 自動再開 | 単一・複数 | PUSH では適用しない。POP かつ window 外だけ seek | 実行済み | `policy-test`、`timeline-position-test`、`history_resume_dom-test` |
| P3 明示再開 | 単一 | History を開いてから resume。Live へ戻す操作では resume しない | 実行済み | `history-resume-button-test` |
| 再開の失敗 | — | window も保存位置も残す。requestId が違う settle は捨てる | 実行済み | `reduce-test`、`timeline-position-test` |

Mix は windowed history の対象外。既存の split Jest が実行済みで、P6 では能力を広げていない。

## 3. P3 / P4 / P5 の相互排他と中断

| 操作 | 中断 | 確認 | 状態 | 置き場所 |
| --- | --- | --- | --- | --- |
| P5 復帰 | P3 が seek_pending | seek せず、保護メッセージ | 実行済み | `timeline_reading_bookmark_restore-test` |
| P5 復帰 | route 変更 | 遅い membership では seek しない | 実行済み | 同 |
| P4 日付ジャンプ | P3 が seek_pending | resume を取り消してから History だけ seek | 今回追加 | `timeline_navigation_exclusion-test` |
| P4 日付ジャンプ / 本文結果ジャンプ | `splitBlocked`、または他カラムが split 所有 | seek せず、進行中 resume と再開予約を残す | 今回追加 | 同 |
| P3 明示再開 | P4 の scroll 未確定 | ジャンプを一度だけ戻し、後から filtered が来ても戻さない | 今回追加 | 同 |
| P4 ジャンプ | 再開予約のあと、History がまだ開いていない | 予約した resume は実行しない | 今回追加 | 同 |
| P5 復帰 | 同じ再開予約 | しおりは適用しない。History が開いたら resume だけ | 今回追加 | 同 |
| P4 ジャンプ | P5 membership の途中 | しおりの id では seek しない | 今回追加 | 同 |
| P5 復帰 | P4 の scroll 未確定 | ジャンプを一度戻し、しおりの id でそのカラムだけ seek | 今回追加 | 同 |
| P4 ジャンプ | カラム id 変更 | 一度だけ戻し、後続 settle では戻さない | 今回追加 | 同 |
| P4 ジャンプ | unmount 後の resolve | 戻さない | 今回追加 | 同 |
| P4 本文ジャンプ | route / source 変更 | stale membership では seek しない | 実行済み | `timeline_text_jump-test` |
| P4 アカウント | モード変更 | 古い lookup 結果を採用しない | 実行済み | `timeline_column_jump-test` |
| P5 | 二重復帰、source 不一致、Redis unknown | 実行済み | `restore-test`、コントローラ復帰テスト |
| 自動 resume | 別カラムの遅い seek commit | 実行済み | `history_resume_dom-test` |

## 4. scroll settle、失敗時の rollback、user_scroll

| 操作 | 条件 | 確認 | 状態 | 置き場所 |
| --- | --- | --- | --- | --- |
| P4 ジャンプ | settle 前の wheel | `user_scroll`。戻さない | 実行済み | `timeline_jump_scroll-test` |
| P4 ジャンプ | 閉じる / unmount | 未確定なら一度だけ戻す | 実行済み | 同 |
| P4 ジャンプ | seek resolve 前の scroll | その後 filtered でも戻さない | 今回追加 | `timeline_navigation_exclusion-test` |
| P5 復帰 | settle 前の scroll | 戻さない。filtered なら戻す | 実行済み | bookmark restore テスト |
| P5 復帰 | seek reject | current なら事前 snapshot を戻す。stale と user_scroll では戻さない | 実行済み | `restore-test`、コントローラ |
| seek 成功 | — | scroll settle まで moved にしない | 実行済み | `scroll-wait-test`、bookmark restore |

描画の scroll settle を実 Chrome のレイアウトで待つことは未実施。jsdom は seek の `scrollStatus` と surface の scroll 通知で代用している。

## 5. カラム、IME、focus、Live と Composer

| 操作 | レイアウト | 確認 | 状態 | 置き場所 |
| --- | --- | --- | --- | --- |
| 日付ジャンプ | 複数カラム二つ | seek は押したカラムの split id だけ | 今回追加 | `timeline_navigation_exclusion-test` |
| ジャンプ / しおり | 複数 | seek payload に Composer の下書き文字列を含めない | 今回追加 | 同 |
| ジャンプを開閉 | 単一 | timeline と composer state を変えない | 実行済み | `status_timeline_split_controller-test` |
| 保存位置 | 複数カラム | 同一 source の別カラムを上書きしない | 実行済み | `registry-test`、`history_resume_dom-test` |
| 本文検索 | — | IME の Enter と compositionend 直後の Enter では検索しない | 実行済み | `timeline_column_text_search-test` |
| しおり名 | — | IME の Enter では保存しない。Escape で閉じる | 実行済み | `timeline_reading_bookmarks-test` |
| 投稿 ID ジャンプ | — | IME の Enter と compositionend 直後の Enter ではジャンプしない | 今回追加 | `timeline_column_jump-test` |
| ジャンプ / 本文検索 | 狭幅 | 結果の縦積み、Escape、focus 復帰 | 実行済み（jsdom） | text search / jump パネルテスト |
| aria-live | — | しおりの結果文言 | 実行済み（jsdom） | bookmark パネルテスト |

テーマ切替、実キーボード、モバイル幅の折り返しは未実施。

## 6. 永続化してはいけないもの

検索語、本文、トークン、window、OAuth token をしおりの行と応答に残さないことは、既存の contract / controller spec と今回の token example で実行済み。クライアントの seek / membership payload から検索語を落とすことは `timeline_seek/model-test` と `session-test` が実行済み。

## 実 Chrome で見る手順

この環境では未実施。ログイン済みの開発インスタンスで、Home を開いた状態から行う。

1. 単一カラム。History を開き、少しスクロールして再開ボタンで戻る。日付ジャンプ、投稿 ID ジャンプ、しおりの保存と復帰を、それぞれ前の操作が終わる前に押して、History だけが動き Live の未読が消えないことを見る。
2. 同じ操作を詳細カラムとホームカラムの二つで行い、隣のカラムと Portable Composer の下書きが残ることを見る。
3. 幅を 400px 前後まで狭め、ジャンプとしおりのパネルが縦に積まれ、Escape で閉じてボタンへ focus が戻ることを見る。
4. ライトとダークでパネルの文字が読めることを見る。
5. 日本語 IME でしおり名、アカウント欄、本文検索を確定し、変換中の Enter で送信されないことを見る。
6. しおり復帰の seek 中にホイールし、離した位置に留まることを見る。通信を切った失敗では、スクロールしていなければ元の History に戻り、スクロールしていれば戻らないことを見る。

## 残リスク

- 実ブラウザの scroll anchoring、sticky header、画像読み込み後の高さ変化は jsdom では未確認。
- resume の thunk が `WINDOW_SEEK_BEGIN` より前にいる短い区間は、コントローラが cancel を先に呼ぶことで閉じた。redux の外で seek を直接叩く経路は見ていない。
- hashtag のキーワードフィルターと domain の停止アカウントを、しおり API の所属判定としては再チェックしていない。復帰時の membership API がそれを担う。
- リモートグループは従来どおり unsupported のまま。

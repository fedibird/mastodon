# Group実装プロファイルと能力判定（P0）

状態: P0。保存済みのスナップショットを読む型、不変条件、この文書、テストだけ。Actor への広告、追加の GET、ディレクトリ API、コンポーザーの条件変更、リモート Group への投稿解放はしない。

親は [#662](https://github.com/fedibird/mastodon/issues/662)。ローカル Group の正本は [#657](https://github.com/fedibird/mastodon/issues/657)。一般公開済みのポータブルコンポーザー（[#650](https://github.com/fedibird/mastodon/issues/650)）の条件は緩めない。

`PostingContext::DiscoveryService` の応答と、ローカル / リモートの投稿認可は変えない。この層は投稿を許可しない。`authorizes_posting` は常に `false` である。

## 三層

| 層 | 問い | P0 が正にする根拠 | 正にしないもの |
|---|---|---|---|
| `implementation` | そのドメインのソフトウェアは何か | ローカルはサーバー自身。リモートは保存済み NodeInfo の `nodes.info` | Actor の `type=Group`、表示名、説明、`info_override` |
| `profile` | その Group がどの配送・投稿方式か | ローカル Group だけが `fedibird_mention_follow_announce` | ソフトウェア名、NodeInfo、FEP-5219 の affiliation |
| `capability` | 何ができ、この viewer は何を持つか | ローカルのサーバー規則、成立済み Follow、`group_role_assignments`、既存の FEP-5219 スナップショット | 不明を `false` にすること、推定を観測にすること |

各証拠は `source`、`authority`、`freshness`、`observed_at`、`expires_at`、`uncertainty` を持つ。

`authority` はこの段階で出るものだけを使う。

| 値 | 意味 |
|---|---|
| `server` | このサーバーの規則またはローカルの表 |
| `self_declared` | 相手が NodeInfo で自分から言ったソフトウェア名 |
| `protocol` | 保存済みの FEP-5219 定義と affiliation |
| `none` | 根拠をその主張に使わない |

`actor_document` と `protocol_feature` はまだ出さない。保存済みの Actor 文書に、レビュー済みの方式 IRI が載るまで空である。

## 実装の読み方

ローカル Account は Node を見ない。`identity` は `server`、`family` と `software_name` は `fedibird` である。ローカルドメインの Node 行が別のソフトウェアを名乗っても、ローカル Group のプロファイルは変わらない。

リモートは `account.node` の保存済み行だけを見る。`Node.resolve_domain` も `UpdateNodeService` も呼ばない。

正の自己申告 (`identity = self_declared` かつ `fedibird_named`) になるのは、次を全部満たすときだけである。

1. Node の domain が Account の domain と一致する。
2. `nodeinfo` が欠落や `error=missing` ではない。欠落しているとき、`info` に残ったソフトウェア名は捨てる。
3. `last_fetched_at` があり、`Node#possibly_stale?` が偽である。境界は `last_fetched_at <= 1.day.ago` で、ちょうど 1 日は stale である。`expires_at` は `last_fetched_at + 1.day` であり、それより前だけが fresh である。`last_fetched_at` が無い行は未取得であり、名前は出さない。
4. 保存済み `uri` のホストが domain と一致する。DNS もリダイレクトもしない。URI が空、http(s) 以外、または別ホストなら、その Node の名前は Actor に結び付けない。
5. `info.software_name` を前後の空白を除いて小文字化した値がちょうど `fedibird` である。`fedibird-fork` や部分一致は名前ではない。

Fedibird は Mastodon のフォークなので、`UpdateNodeService` は upstream を書かない NodeInfo を `upstream_name = mastodon` として保存する。`software_name = fedibird` かつ `upstream_name = mastodon` は通常の自己申告であり、偽装としては扱わない。

次は自己申告でも `fedibird_named` にしない。

- `software_name` は別物で、`upstream_name` だけが `fedibird`。不確実性は `upstream_only`。
- `info_override` だけが `fedibird`。上書きは読まない。`info` と違うとき不確実性は `override_ignored` で、名前は `info` のまま。
- NodeInfo 文書の `software.name` をこの層では解析しない。処理済みの `info` と食い違う文書は、`info` を見る。リンク先への GET はしない。

`family` は `software_name` の完全一致だけを `fedibird / mastodon / mitra / nodebb / lemmy / piefed` に分ける。upstream からは引き上げない。一覧に無い名前は `other` である。

## プロファイル

ローカル Group の `kind` は `fedibird_mention_follow_announce` である。配送は元投稿 URI の通常の Announce（`announce_original_uri`）であり、FEP-1b12 の `Announce(Create)` ではない。投稿の可視性は `public` と `unlisted`、Group への mention と、成立済み Follow を要する。オーナーとモデレーターは Follow とは別の `group_role_assignments` である。この規則をリモートや他実装へコピーしない。

リモート Group の `kind` は、ソフトウェア名が Fedibird でも Mitra でも、常に `unknown` である。`fep_1b12_audience` と `fep_400e` は予約名であり、この段階の結果には出ない。

`compatibility_candidates` は、fresh な自己申告の `software_name` が完全一致したときだけのラベルである。

| software_name | candidate |
|---|---|
| `fedibird` | `fedibird_nodeinfo` |
| `mitra` | `mitra_nodeinfo` |
| `nodebb` | `nodebb_nodeinfo` |
| `lemmy` | `lemmy_nodeinfo` |
| `piefed` | `piefed_nodeinfo` |

候補が付いてもプロファイルは `unknown` のままである。`PostingContext` はこれまで通り、Mitra / NodeBB / Lemmy / PieFed を NodeInfo のソフトウェア名からアダプター選択する。その既存の投稿経路はここへ移さない。逆に、候補 `fedibird_nodeinfo` は `PostingContext::Adapters::FedibirdGroup` をリモートへ開かない。

## リモート Fedibird と、投稿できること

この二つは別の状態である。

| フィールド | 値 | 意味 |
|---|---|---|
| `remote_fedibird` | `not_applicable` | ローカルか、Group ではない |
| `remote_fedibird` | `self_declared` | 上の条件で NodeInfo が `fedibird` と名乗っている |
| `remote_fedibird` | `not_determined` | それ以外のリモート Group |
| `remote_fedibird` | `determined` | 将来の明示的な方式広告。P0 は拒否する |
| `fedibird_posting` | `server_local` | ローカル Group の既存契約。新しい許可ではない |
| `fedibird_posting` | `withheld` | リモート Group。自己申告があっても投稿経路は開かない |
| `fedibird_posting` | `not_applicable` | Group ではない |
| `authorizes_posting` | `false` | このオブジェクトは認可結果ではない |

`fedibird_named` が真なのは `remote_fedibird = self_declared` のときだけである。ローカルの `software_name = fedibird` では立たない。

## 能力

Group の actor 能力は、viewer が誰でも同じである。状態は `observed`（見た）、`denied`（サーバーが否定した）、`unknown`（判定しない）、`unfetched`（スナップショットが無い）、`withheld`（この段階が開かない）である。`estimated` は予約であり出さない。`unknown` と `unfetched` の値は `nil` であり、`false` ではない。

ローカル Group:

| 名前 | 状態 | 値 |
|---|---|---|
| `can_follow` | observed | `true` |
| `follow_as_membership` | observed | `true` |
| `requires_group_mention` | observed | `true` |
| `allowed_visibilities` | observed | `public`, `unlisted` |
| `group_announce_delivery` | observed | `announce_original_uri` |
| `roles_independent_of_follow` | observed | `true` |
| `fep_1b12_audience` | denied | `false` |
| `fep_400e_append` | denied | `false` |
| `remote_posting_released` | withheld | `false` |

リモート Group は最後の `remote_posting_released` 以外をすべて `unknown` / `nil` にする。Follow がローカルに既にあっても、mention 必須や可視性や FEP-1b12 を真にしない。

`remote_posting_released = false` はローカル Group にも付く。ローカルのコンポーザーは従来の `PostingContext` が開き、このフラグでは開かない。

viewer を渡したときだけ、別の配列 `viewer_capabilities` を付ける。公開メタデータには含めない。

| 名前 | ローカル | リモート |
|---|---|---|
| `membership_follow` | 成立済み Follow があるとき observed `true`。無いとき denied `false`。Follow 申請はメンバーではない | unknown。Follow 行があっても読まない |
| `role` | 有効な `group_role_assignments` の `owner` か `moderator`。無ければ denied `none`。Follow とは独立 | unknown。affiliation の `owner` や `admin` を役職にしない |
| `fep_5219_can_create` | 既存の定義スナップショットと affiliation スナップショットを `GroupPermissionEvidenceResolver` で結んだ結果 | 同じ。`allowed` は observed `true`。一致しない fresh は unknown であり denied ではない |
| `fep_5219_can_view` | 同上 | 同上 |
| `can_post` | 常に unknown / `nil` | 常に unknown / `nil` |

FEP-5219 の `canCreate = none` は「affiliation 不要」というプロトコル上の観測であり、Fedibird 方式の投稿許可でも役職でもない。`GroupPermissionEvidenceResolver` が `allowed` を返すのは、定義スナップショットが fresh のときだけである。識別子が `none` のときは affiliation の鮮度を見ない。それ以外の識別子は、affiliation も fresh で一致したときだけである。定義が stale または未取得なら、`none` でも `allowed` にならない。この層は、その不変条件を満たす `allowed` の証拠鮮度だけを `fresh` にする。条件を外れた `allowed` は fresh な観測として保存せず、契約違反にする。`none` 以外でどちらかが stale なら能力は unknown、鮮度は stale であり、否定にはしない。未取得は `unfetched` である。定義と affiliation の鮮度はこれまで通り各 1 日である。

## 公開メタデータ

`GroupProtocol.public_metadata(account)` は viewer を受け取らない。返すキーは `PUBLIC_KEYS` だけである。所属、役職、Follow、FEP の関係名、viewer の URI は入らない。ディレクトリが後で使うのはこの形までとする。viewer の機微な結果は `GroupProtocol.assess(account, viewer:)` の `viewer_capabilities` に残り、別 API にする。この段階ではエンドポイントを足さない。

## 方式広告の案（未実装）

リモートを `determined` にするには、ソフトウェア名でも `type=Group` でもなく、Group Actor が方式を明示する必要がある。P0 はどの形も配信しない。`explicit_protocol_feature` は後続が接続するまでの nil であり、プロファイルの読み取りはこれを呼ばない。保存済み文書に方式 IRI が後から載っても、この段階は採用しない。

検討した案:

1. **Fedibird 独自の IRI（候補）**。既に取得済みの Actor 文書へ、追加 GET なしで載せる。例: `https://fedibird.com/ns#MentionFollowAnnounce`。意味は「mention + 成立済み Follow + public/unlisted + 元投稿 URI の Announce」。FEP-1b12 の `Announce(Create)` や FEP-400e の Add ではない、と IRI で分ける。他実装は無視する。名前空間を先に配信すると、標準化の前に観測点が固定される。
2. **FEP の方式 IRI（望ましい着地点）**。Group Actor が `groupProtocols` のような複数値で IRI を出す。Fedibird 方式、FEP-1b12、FEP-400e は別の IRI であり、一つが見えても他方の規則をコピーしない。FEP-5219 は権限の語彙であり、この IRI の代わりにしない。最新の本文を確認するまで、affiliation からオーナー権限を付与しない。
3. **NodeInfo の `metadata.features`（採用しない）**。ドメインの自己申告であり、そのドメインの個々の Group の方式ではない。互換候補に残す余地はあるが、P0 は読まない。

採用するまでのフォールバックは次の順で、下の段は上の段の主張を兼ねない。

1. ローカル Group はサーバー権威のプロファイル。
2. レビュー済みの明示的な方式 IRI。保存列が無く、P0 はフックを呼ばない。Actor を取り直さない。
3. fresh で Actor に結び付いた NodeInfo の `software_name` は互換候補だけ。
4. それ以外は `unknown`。欠落、期限切れ、ホスト不一致、フォーク形の名前は、不明であって否定ではない。

## 取得と負荷

この層の 1 回の判定は HTTP を出さない。署名付き GET、リダイレクト、NodeInfo や Actor の再取得をしない。`169.254.169.254` や別ホストの inbox が保存されていても、そこへは接続しない。

クエリの上限はテストが固定する。Account と Node を先に読み込んだリモート Group は、viewer 無しなら追加クエリ 0。ローカル Group は viewer 無しなら 0。viewer ありのローカルは、Follow の有無と有効な役職の 2 クエリまで。リモートで affiliation が fresh のときだけ、既存リゾルバが関係行を 1 回読む。fresh でなければその SELECT はしない。リモートの Follow と役職は読まない。

期限切れへの更新は、この層が結果をメモしないことで足りる。同じ Account を、Node の `last_fetched_at` や `nodeinfo` や affiliation の取得時刻を変えたあと再評価すれば、次の結果が新しい行を見る。

## この段階でやらないこと

- `determined` の付与、リモート Fedibird のコンポーザー開放、投稿 API の追加
- ActivityPub Actor へのプロパティ追加、NodeInfo や Actor への追加 GET
- ディレクトリのエンドポイント、viewer 所属の公開
- FEP-1b12 への配送切替、FEP-5219 からローカル役職への読み替え
- `PostingContext::DiscoveryService` のステータス、コンテキスト、認可境界の変更
- 本番での有効化フラグ。呼び出し元はまだコンポーザーでもディレクトリでもない

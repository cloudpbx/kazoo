%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, 2600Hz INC
%%% @doc
%%%
%%%
%%% @end
%%% @contributors
%%%   Pierre Fenoll
%%%-------------------------------------------------------------------
-module(knm_maintenance).

-include("knm.hrl").

-export([fix_account_numbers/1
        ,fix_accounts_numbers/1

        ,migrate/0, migrate/1

        ,generate_numbers/4

        ,delete/1

        ,maybe_update_number_services_view/1
        ]).

-define(TIME_BETWEEN_ACCOUNTS_MS
       ,kapps_config:get_integer(?KNM_CONFIG_CAT, <<"time_between_accounts_ms">>, ?MILLISECONDS_IN_SECOND)).

-define(TIME_BETWEEN_NUMBERS_MS
       ,kapps_config:get_integer(?KNM_CONFIG_CAT, <<"time_between_numbers_ms">>, ?MILLISECONDS_IN_SECOND)).

-define(LOG(Format, Args)
       ,begin
            lager:debug(Format, Args),
            io:format(Format ++ "\n", Args)
        end
       ).

%% API

%% @public
-spec maybe_update_number_services_view(ne_binary()) -> ok.
maybe_update_number_services_view(?MATCH_ACCOUNT_ENCODED(_)=AccountDb) ->
    Classifiers = knm_converters:available_classifiers(), %%TODO: per-account classifiers.
    Pairs = [{Classification, kz_json:get_value([Classification, <<"regex">>], JObj)}
             || JObj <- [Classifiers],
                Classification <- kz_json:get_keys(JObj)
            ],
    {Classifications, Regexs} = lists:unzip(lists:keysort(1, Pairs)),
    MapView = number_services_map(Classifications, Regexs),
    RedView = number_services_red(Classifications),
    ViewName = <<"_design/numbers">>,
    {ok, View} = kz_datamgr:open_doc(AccountDb, ViewName),
    NewView = kz_json:set_values([{[<<"views">>, <<"reconcile_services">>, <<"map">>], MapView}
                                 ,{[<<"views">>, <<"reconcile_services">>, <<"reduce">>], RedView}
                                 ]
                                ,View
                                ),
    case kz_json:are_identical(View, NewView) of
        true -> ?LOG("View is up to date.", []);
        false ->
            true = kz_datamgr:db_view_update(AccountDb, [{ViewName, NewView}]),
            ?LOG("View updated!", [])
    end.

%% @public
-spec fix_accounts_numbers([ne_binary()]) -> 'ok'.
-spec fix_account_numbers(ne_binary()) -> 'ok'.
fix_accounts_numbers(Accounts) ->
    AccountDbs = lists:usort([kz_util:format_account_db(Account) || Account <- Accounts]),
    foreach_pause_in_between(?TIME_BETWEEN_ACCOUNTS_MS, fun fix_account_numbers/1, AccountDbs).

fix_account_numbers(AccountDb = ?MATCH_ACCOUNT_ENCODED(A,B,Rest)) ->
    kz_util:put_callid(?MODULE),
    ?LOG("########## fixing [~s] ##########", [AccountDb]),
    ?LOG("[~s] getting numbers from account db", [AccountDb]),
    DisplayPNs = get_DIDs(AccountDb, <<"phone_numbers/crossbar_listing">>),
    ?LOG("[~s] getting numbers from callflow", [AccountDb]),
    put(callflow_DIDs, get_DIDs(AccountDb, <<"callflows/listing_by_number">>)),
    ?LOG("[~s] getting numbers from trunkstore", [AccountDb]),
    put(trunkstore_DIDs, get_DIDs(AccountDb, <<"trunkstore/lookup_did">>)),
    AccountId = ?MATCH_ACCOUNT_RAW(A, B, Rest),
    Leftovers =
        lists:foldl(fun (NumberDb, Leftovers) ->
                            Fixer = fun (DID) -> fix_docs(AccountDb, NumberDb, DID) end,
                            ?LOG("[~s] getting numbers from ~s", [AccountDb, NumberDb]),
                            AuthoritativePNs = get_DIDs_assigned_to(NumberDb, AccountId),
                            ?LOG("[~s] start fixing ~s", [AccountDb, NumberDb]),
                            foreach_pause_in_between(?TIME_BETWEEN_NUMBERS_MS
                                                    ,Fixer
                                                    ,gb_sets:to_list(AuthoritativePNs)
                                                    ),
                            ?LOG("[~s] done fixing ~s", [AccountDb, NumberDb]),
                            timer:sleep(?TIME_BETWEEN_ACCOUNTS_MS),
                            gb_sets:subtract(Leftovers, AuthoritativePNs)
                    end
                   ,DisplayPNs
                   ,knm_util:get_all_number_dbs()
                   ),
    _ = knm_phone_number:push_stored(), %% Bulk doc writes
    ToRm0 = gb_sets:to_list(Leftovers),
    lists:foreach(fun (DID) ->
                          ?LOG("########## found alien [~s] doc: ~s ##########", [AccountDb, DID])
                  end
                 ,ToRm0
                 ),
    ToRm = [DID
            || DID <- ToRm0,
               false =:= is_assigned_to(AccountDb, DID, AccountId),
               ok =:= ?LOG("########## will remove [~s] doc: ~s ##########", [AccountDb, DID])
           ],
    _ = kz_datamgr:del_docs(AccountDb, ToRm),
    ?LOG("########## updating view [~s] ##########", [AccountDb]),
    maybe_update_number_services_view(AccountDb),
    ?LOG("########## done fixing [~s] ##########", [AccountDb]);
fix_account_numbers(Account = ?NE_BINARY) ->
    fix_account_numbers(kz_util:format_account_db(Account)).

-spec migrate() -> 'ok'.
migrate() ->
    AccountDbs = kapps_util:get_all_accounts(),
    foreach_pause_in_between(?TIME_BETWEEN_ACCOUNTS_MS, fun migrate/1, AccountDbs).

-spec migrate(ne_binary()) -> 'ok'.
migrate(AccountDb) ->
    fix_account_numbers(AccountDb),
    _ = kz_datamgr:del_doc(AccountDb, <<"phone_numbers">>),
    'ok'.

%%%===================================================================
%%% Internal functions
%%%===================================================================

escape(?NE_BINARY=Bin0) ->
    StartSz = byte_size(Start= <<"<<">>),
    EndSz   = byte_size(End  = <<">>">>),
    Bin = iolist_to_binary(io_lib:format("~p", [Bin0])),
    SizeOfWhatIWant = byte_size(Bin) - (StartSz + EndSz),
    <<Start:StartSz/binary, Escaped:SizeOfWhatIWant/binary, End:EndSz/binary>> = Bin,
    Escaped.

number_services_map(Classifications, Regexs) ->
    Features = ?DEFAULT_ALLOWED_FEATURES,
    iolist_to_binary(
      ["function(doc) {"
       "  if (doc.pvt_type != 'number' || doc.pvt_deleted) return;"
       "  var e164 = doc._id;"
       "  var resC = {", kz_util:iolist_join($,, [[$',C,"':0"] || C <- Classifications]), "};"
       %% "log('+14157125234'.match(",escape(<<"\\d+">>),"));"
       "  if (false) return;"
      ,[["  else if (e164.match(", escape(R), ")) resC['", C, "'] = 1;"]
        || {C, R} <- lists:zip(Classifications, Regexs)
       ]
      ,"  var resF = {", kz_util:iolist_join($,, [[$',F,"':0"] || F <- Features]), "};"
       "  var features = [", kz_util:iolist_join($,,[[$',F,$'] || F <- Features]), "];"
       "  var used = doc.pvt_features || {};"
       "  for (var i in features) {"
       "    var feature = features[i];"
       "    if (used.hasOwnProperty(feature))"
       "      resF[feature] += 1;"
       "  }"
       "log(1);log(resC); log(2);log(resF);"
       "  emit(doc._id, {'classifications':resC, 'features':resF});"
       "}"
      ]).

number_services_red(Classifications) ->
    Features = ?DEFAULT_ALLOWED_FEATURES,
    iolist_to_binary(
      ["function(Keys, Values, _Rereduce) {"
       "  var resC = {", kz_util:iolist_join($,, [[$',C,"':0"] || C <- Classifications]), "};"
       "  var resF = {", kz_util:iolist_join($,, [[$',F,"':0"] || F <- Features]), "};"
       "  var keysC = [", kz_util:iolist_join($,, [[$',C,$'] || C <- Classifications]), "];"
       "  var keysF = [", kz_util:iolist_join($,, [[$',F,$'] || F <- Features]), "];"
       "  for (var i in Values) {"
       "    var Value = Values[i];"
       "    for (var k in keysC) {"
       "      var key = keysC[k];"
       "      resC[key] += Value['classifications'][key] || 0;"
       "    }"
       "    for (var k in keysF) {"
       "      var key = keysF[k];"
       "      resF[key] += Value['features'][key] || 0;"
       "    }"
       "  }"
       "log(3); log(resC); log(4);log(resF);"
       "  return {'classifications':resC, 'features':resF};"
       "}"
      ]).

-spec foreach_pause_in_between(non_neg_integer(), fun(), list()) -> 'ok'.
foreach_pause_in_between(_, _, []) -> 'ok';
foreach_pause_in_between(_, Fun, [Element]) ->
    _ = Fun(Element),
    'ok';
foreach_pause_in_between(Time, Fun, [Element|Elements]) ->
    _ = Fun(Element),
    timer:sleep(Time),
    foreach_pause_in_between(Time, Fun, Elements).

-spec fix_docs(ne_binary(), ne_binary(), ne_binary()) -> ok.
fix_docs(AccountDb, NumberDb, DID) ->
    Res = kz_datamgr:open_doc(AccountDb, DID),
    fix_docs(Res, AccountDb, NumberDb, DID).

fix_docs({error, timeout}, _AccountDb, _, _DID) ->
    ?LOG("getting ~s from ~s timed out, skipping", [_DID, _AccountDb]);
fix_docs({error, _R}, _AccountDb, _, DID) ->
    ?LOG("failed to get ~s from ~s (~p), creating it", [DID, _AccountDb, _R]),
    %% knm_number:update/2,3 ensures creation of doc in AccountDb
    knm_number:update(DID, [{fun knm_phone_number:set_used_by/2, app_using(DID)}]);
fix_docs({ok, Doc}, AccountDb, NumberDb, DID) ->
    Res = kz_datamgr:open_doc(NumberDb, DID),
    fix_docs(Res, Doc, AccountDb, NumberDb, DID).

fix_docs({error, timeout}, _, _, _NumberDb, _DID) ->
    ?LOG("getting ~s from ~s timed out, skipping", [_DID, _NumberDb]);
fix_docs({error, _R}, _, _, _NumberDb, _DID) ->
    ?LOG("~s disappeared from ~s (~p), skipping", [_DID, _NumberDb]);
fix_docs({ok, NumDoc}, Doc, AccountDb, NumberDb, DID) ->
    case app_using(DID) =:= kz_json:get_ne_binary_value(?PVT_USED_BY, NumDoc)
        andalso have_same_pvt_values(NumDoc, Doc)
        andalso are_features_available_synced(NumDoc)
    of
        true -> ?LOG("~s already sync-ed", [DID]);
        false ->
            JObj = kz_json:merge_jobjs(kz_json:public_fields(NumDoc)
                                      ,kz_json:public_fields(Doc)
                                      ),
            ?LOG("syn-ing ~s", [DID]),
            Routines = [{fun knm_phone_number:set_used_by/2, app_using(DID)}
                       ,{fun knm_phone_number:update_doc/2, JObj}
                       ],
            knm_number:update(DID, Routines, [{auth_by, ?KNM_DEFAULT_AUTH_BY}
                                              %% No caching + bulk doc writes
                                             ,{batch_run, true}
                                             ]),
            ok
    end.


-type dids() :: gb_sets:set(ne_binary()).
-spec get_DIDs(ne_binary(), ne_binary()) -> dids().
get_DIDs(AccountDb, View) ->
    case kz_datamgr:get_result_keys(AccountDb, View, []) of
        {'ok', DIDs} -> gb_sets:from_list(DIDs);
        {'error', _R} ->
            ?LOG("failed to get ~s DIDs from ~s: ~p", [View, AccountDb, _R]),
            gb_sets:new()
    end.

-spec get_DIDs_assigned_to(ne_binary(), ne_binary()) -> dids().
get_DIDs_assigned_to(NumberDb, AssignedTo) ->
    ViewOptions = [{startkey, [AssignedTo]}
                  ,{endkey, [AssignedTo, kz_json:new()]}
                  ],
    case kz_datamgr:get_results(NumberDb, <<"numbers/assigned_to">>, ViewOptions) of
        {ok, JObjs} -> gb_sets:from_list(lists:map(fun kz_doc:id/1, JObjs));
        {error, _R} ->
            lager:debug("failed to get ~s DIDs from ~s: ~p", [AssignedTo, NumberDb, _R]),
            gb_sets:new()
    end.

-spec have_same_pvt_values(kz_json:object(), kz_json:object()) -> boolean().
have_same_pvt_values(NumDoc0, Doc0) ->
    NumDoc = cleanse(kz_json:private_fields(NumDoc0)),
    Doc = cleanse(kz_json:private_fields(Doc0)),
    NumDoc == Doc.

-spec are_features_available_synced(kz_json:object()) -> boolean().
are_features_available_synced(NumDoc) ->
    kz_json:get_value(?PVT_FEATURES_AVAILABLE, NumDoc) =:=
        knm_phone_number:features_available(
          knm_phone_number:from_json(NumDoc)
         ).

-spec cleanse(kz_json:object()) -> kz_json:object().
cleanse(JObj) ->
    kz_json:delete_keys([<<"id">>, <<"_id">>
                        ,<<"_rev">>
                        ,?PVT_AUTH_BY
                        ,?PVT_STATE_LEGACY
                        ,?PVT_MODIFIED
                        ,?PVT_CREATED
                        ]
                       ,JObj
                       ).

-spec app_using(ne_binary()) -> api_ne_binary().
app_using(DID) ->
    case gb_sets:is_element(DID, get(callflow_DIDs)) of
        true -> <<"callflow">>;
        false ->
            case gb_sets:is_element(DID, get(trunkstore_DIDs)) of
                true -> <<"trunkstore">>;
                false -> undefined
            end
    end.

-spec is_assigned_to(ne_binary(), ne_binary(), ne_binary()) -> boolean().
is_assigned_to(AccountDb, DID, AccountId) ->
    case kz_datamgr:open_doc(AccountDb, DID) of
        {error, _R} ->
            lager:debug("~s's ~s temporarily unavailable, skipping", [AccountDb, DID]),
            true;
        {ok, Doc} ->
            AccountId =/= kz_json:get_ne_binary_value(?PVT_ASSIGNED_TO, Doc)
    end.


-spec generate_numbers(ne_binary(), ne_binary(), pos_integer(), non_neg_integer()) -> 'ok'.
generate_numbers(Type, AccountId, StartingNumber, Quantity) ->
    M = kz_util:to_atom(<<"knm_", Type/binary>>, 'true'),
    M:generate_numbers(AccountId, kz_util:to_integer(StartingNumber), kz_util:to_integer(Quantity)).


-spec delete(ne_binary()) -> 'no_return'.
delete(Num) ->
    case knm_number:delete(Num, knm_number_options:default()) of
        {'ok', _} -> io:format("Removed ~s\n", [Num]);
        {'error', _R} -> io:format("ERROR: ~p\n", [_R])
    end,
    'no_return'.

%% End of Module

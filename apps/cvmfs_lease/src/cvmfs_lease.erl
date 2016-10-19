%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc
%%%
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cvmfs_lease).

-compile([{parse_transform, lager_transform}]).

-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, stop/0
        ,request_lease/3, end_lease/2
        ,get_leases/0, clear_leases/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%% Records used as table entries

-record(lease, { s_path :: {binary(), binary()} % repo + subpath which is locked
               , u_id   :: binary()  % user identifier
               , time   :: integer()  % timestamp (time when lease acquired)
               }).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%%--------------------------------------------------------------------
%% @doc
%% Stops the server (only useful without a supervision tree)
%%
%% @spec stop() -> ok
%% @end
%%--------------------------------------------------------------------
stop() ->
    gen_server:cast(?MODULE, stop).

%%--------------------------------------------------------------------
%% @doc
%% Requests a new lease
%%
%% @spec request_lease(User, Repo, Path)) -> {ok, LeaseId}
%%                                         | {busy, TimeRemaining}
%% @end
%%--------------------------------------------------------------------
-spec request_lease(binary(), binary(), binary()) -> {ok, binary()}
                                                   | {busy, integer()}.
request_lease(User, Repo, Path) ->
    gen_server:call(?MODULE, {lease_req, new_lease, {User, Repo, Path}}).

%%--------------------------------------------------------------------
%% @doc
%% Gives up an existing lease
%%
%% @spec end_lease(Path, Repo) -> ok | {error, lease_not_found}
%% @end
%%--------------------------------------------------------------------
end_lease(Repo, Path) ->
    gen_server:call(?MODULE, {lease_req, end_lease, {Repo, Path}}).

%%--------------------------------------------------------------------
%% @doc
%% Returns list of all active leases
%%
%% @spec get_leases() -> Leases
%% @end
%%--------------------------------------------------------------------
-spec get_leases() -> [#lease{}].
get_leases() ->
    gen_server:call(?MODULE, {lease_req, get_leases}).

%%--------------------------------------------------------------------
%% @doc
%% Clears all existing leases from the table.
%%
%% @spec clear_leases() -> ok.
%% @end
%%--------------------------------------------------------------------
-spec clear_leases() -> ok.
clear_leases() ->
    gen_server:call(?MODULE, {lease_req, clear_leases}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(MnesiaSchema) ->
    mnesia:create_table(lease, [{MnesiaSchema, [node() | nodes()]}
                               ,{type, set}
                               ,{attributes, record_info(fields, lease)}]),
    ok = mnesia:wait_for_tables([lease], 10000),
    lager:info("Lease table initialized"),
    {ok, {}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({lease_req, new_lease, {User, Repo, Path}}, _From, State) ->
    Reply = priv_new_lease(User, Repo, Path, State),
    lager:info("Request received: {new_lease, ~p} -> Reply: ~p"
              ,[{User, Repo, Path}, Reply]),
    {reply, Reply, State};
handle_call({lease_req, end_lease, {Repo, Path}}, _From, State) ->
    Reply = priv_end_lease(Repo, Path),
    lager:info("Request received: {end_lease, ~p} -> Reply: ~p"
              ,[{Repo, Path}, Reply]),
    {reply, Reply, State};
handle_call({lease_req, get_leases}, _From, State) ->
    Reply = priv_get_leases(),
    lager:info("Request received: {get_leases} -> Reply: ~p"
              ,[Reply]),
    {reply, Reply, State};
handle_call({lease_req, clear_leases}, _From, State) ->
    Reply = priv_clear_leases(),
    lager:info("Request received: {clear_leases} -> Reply: ~p"
              ,[Reply]),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(stop, State) ->
    lager:info("Cast received: stop"),
    {stop, normal, State};
handle_cast(Msg, State) ->
    lager:info("Cast received: ~p -> noreply", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(Info, State) ->
    lager:warning("Unknown message received: ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    lager:info("Terminating with reason: ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(OldVsn, State, _Extra) ->
    lager:info("Code change request received. Old version: ~p", [OldVsn]),
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

priv_new_lease(User, Repo, Path, _State) ->
    {ok, MaxLeaseTime} = application:get_env(cvmfs_services, max_lease_time),

    %% Match statement that selects all rows with a given repo,
    %% returning a list of {Path, Time} pairs
    MS = ets:fun2ms(fun(#lease{u_id = U, time = T, s_path = {R, P}}) when R =:= Repo ->
                            {P, T}
                    end),

    T = fun() ->
                CurrentTime = erlang:system_time(milli_seconds),

                %% We select the rows related to a given repository
                Results = mnesia:select(lease, MS),

                %% We filter out entries which don't overlap with {Repo, Path}
                case lists:filter(fun({P, _}) ->
                                          cvmfs_lease_path_util:are_overlapping(P, Path)
                                  end,
                                  Results) of
                    %% An everlapping path was found
                    [{P, Time} | _] ->
                        RemainingTime = MaxLeaseTime - (CurrentTime - Time),
                        case RemainingTime > 0 of
                            %% The old lease is still valid, return busy message
                            true ->
                                {busy, RemainingTime};
                            %% The old lease is expired. Delete it and insert the new one
                            false ->
                                mnesia:delete({lease, {Repo, P}}),
                                priv_write_row(User, Repo, Path)
                        end;
                    %% No overlapping paths were found; just insert the new entry
                    _ ->
                        priv_write_row(User, Repo, Path)
                end
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.

priv_end_lease(Repo, Path) ->
    T = fun() ->
                case mnesia:read(lease, {Repo, Path}) of
                    [] ->
                        {error, lease_not_found};
                    _ ->
                        mnesia:delete({lease, {Repo, Path}})
                end
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.

priv_get_leases() ->
    T = fun() ->
                mnesia:foldl(fun(Lease, Acc) -> [Lease | Acc] end, [], lease)
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.

priv_clear_leases() ->
    {atomic, Result} = mnesia:clear_table(lease),
    Result.

priv_write_row(User, Repo, Path) ->
    mnesia:write(#lease{s_path = {Repo, Path},
                        u_id = User,
                        time = erlang:system_time(milli_seconds)}).

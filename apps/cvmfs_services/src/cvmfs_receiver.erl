%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc cvmfs_receiver
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(cvmfs_receiver).

-compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

%% API
-export([start_link/1,
        generate_token/3,
        get_token_id/1,
        submit_payload/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


%% Request types (enum receiver::Request) from "cvmfs.git/cvmfs/receiver/reactor.h"
-define(kQuit,0).
-define(kEcho,1).
-define(kGenerateToken,2).
-define(kGetTokenId,3).
-define(kCheckToken,4).
-define(kSubmitPayload,5).
-define(kError,6).

%% Worker comm timeout
-define(WORKER_REPLY_TIMEOUT, 3000).


%%%===================================================================
%%% Type specifications
%%%===================================================================
-type submission_error() :: {error,
                             lease_expired |
                             invalid_lease |
                             invalid_key |
                             invalid_macaroon |
                             worker_timeout |
                             path_violation |
                             other_error}.
-type submit_payload_result() :: {ok, payload_added} |
                                 {ok, payload_added, lease_ended} |
                                 submission_error().
-type payload_submission_data() :: {LeaseToken :: binary()
                                   ,Payload :: binary()
                                   ,Digest :: binary()
                                   ,HeaderSize :: integer()}.


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
    gen_server:start_link(?MODULE, Args, []).


-spec generate_token(KeyId, Path, MaxLeaseTime) -> {Token, Public, Secret}
                                                       when KeyId :: binary(),
                                                            Path :: binary(),
                                                            MaxLeaseTime :: integer(),
                                                            Token :: binary(),
                                                            Public :: binary(),
                                                            Secret :: binary().
generate_token(KeyId, Path, MaxLeaseTime) ->
    WorkerPid = poolboy:checkout(cvmfs_receiver_pool),
    Result = gen_server:call(WorkerPid, {worker_req, generate_token, {KeyId, Path, MaxLeaseTime}}),
    poolboy:checkin(cvmfs_receiver_pool, WorkerPid),
    Result.


-spec get_token_id(Token) -> {ok, PublicId} | {error, invalid_macaroon}
                                 when Token :: binary(),
                                      PublicId :: binary().
get_token_id(Token) ->
    WorkerPid = poolboy:checkout(cvmfs_receiver_pool),
    Result = gen_server:call(WorkerPid, {worker_req, get_token_id, Token}),
    poolboy:checkin(cvmfs_receiver_pool, WorkerPid),
    Result.


-spec submit_payload(SubmissionData, Secret) -> submit_payload_result()
                                                    when SubmissionData :: payload_submission_data(),
                                                         Secret :: binary().
submit_payload(SubmissionData, Secret) ->
    WorkerPid = poolboy:checkout(cvmfs_receiver_pool),
    Result = gen_server:call(WorkerPid, {worker_req, submit_payload, {SubmissionData, Secret}}),
    poolboy:checkin(cvmfs_receiver_pool, WorkerPid),
    Result.


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
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("CVMFS receiver initialized at PID ~p.", [self()]),

    #{executable_path := Exec} = Args,

    WorkerArgs = ["-i", integer_to_list(3), "-o", integer_to_list(4)],
    WorkerPort = open_port({spawn_executable, Exec}, [{args, WorkerArgs},
                                                      stream,
                                                      binary,
                                                      nouse_stdio,
                                                      exit_status]),

    %% Send a kEcho request to the worker
    lager:info("Sending kEcho request to worker process."),
    p_write_request(WorkerPort, ?kEcho, <<"Ping">>),
    {ok, {Size, Msg}} = p_read_reply(WorkerPort),
    lager:info("Received kEcho reply from worker: size: ~p, msg: ~p", [Size, Msg]),
    {ok, #{worker => WorkerPort}}.

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
handle_call({worker_req, generate_token, {KeyId, Path, MaxLeaseTime}}, _From, State) ->
    #{worker := WorkerPort} = State,
    Reply = p_generate_token(KeyId, Path, MaxLeaseTime, WorkerPort),
    lager:info("Worker ~p request: {generate_token, {~p, ~p, ~p}} -> Reply: ~p",
               [self(), KeyId, Path, MaxLeaseTime, Reply]),
    {reply, Reply, State};
handle_call({worker_req, get_token_id, Token}, _From, State) ->
    #{worker := WorkerPort} = State,
    Reply = p_get_token_id(Token, WorkerPort),
    lager:info("Worker ~p request: {get_token_id, ~p} -> Reply: ~p",
               [self(), Token, Reply]),
    {reply, Reply, State};
handle_call({worker_req, submit_payload, {{Token, _, Digest, HeaderSize} = SubmissionData, Secret}}, _From, State) ->
    #{worker := WorkerPort} = State,
    Reply = p_submit_payload(SubmissionData, Secret, WorkerPort),
    lager:info("Worker ~p request: {submit_payload, {{~p, PAYLOAD_NOT_SHOWN, ~p, ~p} ~p}} -> Reply: ~p",
               [self(), Token, Digest, HeaderSize, Secret, Reply]),
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
handle_info({Port, {exit_status, Status}}, State) ->
    lager:info("Worker process ~p exited with status: ~p", [Port, Status]),
    {noreply, State};
handle_info({'EXIT', Port, Reason}, State) ->
    lager:info("Port ~p exited with reason: ~p", [Port, Reason]),
    {noreply, State};
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
terminate(Reason, State) ->
    #{worker := WorkerPort} = State,

    %% Send the kQuit request to the worker
    lager:info("Sending kQuit request to worker process."),
    p_write_request(WorkerPort, ?kQuit, <<"">>),
    {ok, {2, <<"ok">>}} = p_read_reply(WorkerPort),
    port_close(WorkerPort),
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
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec p_generate_token(KeyId, Path, MaxLeaseTime, WorkerPort)
                      -> {Token, Public, Secret}
                             when KeyId :: binary(),
                                  Path :: binary(),
                                  MaxLeaseTime :: integer(),
                                  WorkerPort :: port(),
                                  Token :: binary(),
                                  Public :: binary(),
                                  Secret :: binary().
p_generate_token(KeyId, Path, MaxLeaseTime, WorkerPort) ->
    ReqBody = jsx:encode(#{<<"key_id">> => KeyId, <<"path">> => Path,
                          <<"max_lease_time">> => MaxLeaseTime}),
    p_write_request(WorkerPort, ?kGenerateToken, ReqBody),
    {ok, {_Size, ReplyBody}} = p_read_reply(WorkerPort),
    #{<<"token">> := Token, <<"id">> := Public, <<"secret">> := Secret}
        = jsx:decode(ReplyBody, [return_maps]),
    {Public, Secret, Token}.


-spec p_get_token_id(Token, WorkerPort)
                    -> {ok, PublicId} | {error, invalid_macaroon}
                           when Token :: binary(),
                                WorkerPort :: port(),
                                PublicId :: binary().
p_get_token_id(Token, WorkerPort) ->
    p_write_request(WorkerPort, ?kGetTokenId, Token),
    case p_read_reply(WorkerPort) of
        {ok, {_, Reply}} ->
            case jsx:decode(Reply, [return_maps]) of
                #{<<"status">> := <<"ok">>, <<"id">> := PublicId} ->
                    {ok, PublicId};
                #{<<"status">> := <<"error">>, <<"reason">> := _Reason} ->
                    {error, invalid_macaroon}
            end;
        {error, _} ->
            {error, invalid_macaroon}
    end.


-spec p_submit_payload(SubmissionData, Secret, WorkerPort) -> submit_payload_result()
                                                    when SubmissionData :: payload_submission_data(),
                                                         Secret :: binary(),
                                                         WorkerPort :: port().
p_submit_payload({LeaseToken, _Payload, _Digest, _HeaderSize}, Secret, WorkerPort) ->
    ReqBody = jsx:encode(#{<<"token">> => LeaseToken, <<"secret">> => Secret}),
    p_write_request(WorkerPort, ?kCheckToken, ReqBody),
    case p_read_reply(WorkerPort) of
        {ok, {_, TokenCheckReply}} ->
            case jsx:decode(TokenCheckReply, [return_maps]) of
                #{<<"status">> := <<"ok">>, <<"path">> := Path} ->
                    lager:info("TODO: Submit payload for path ~p", [Path]),
                    {ok, payload_added};
                #{<<"status">> := <<"error">>, <<"reason">> := <<"expired_token">>} ->
                    {error, lease_expired};
                #{<<"status">> := <<"error">>, <<"reason">> := <<"invalid_token">>} ->
                    {error, invalid_lease}
            end;
        {error, worker_timeout} ->
            lager:error("Timeout reached waiting for reply from worker ~p", [WorkerPort]),
            {error, worker_timeout}
    end.


p_write_request(Port, Request, Msg) ->
    Size = size(Msg),
    Buffer = <<Request:32/integer-signed-little,Size:32/integer-signed-little,Msg/binary>>,
    Port ! {self(), {command, Buffer}}.

p_read_reply(Port) ->
    receive
        {Port, {data, <<Size:32/integer-signed-little,Msg/binary>>}} ->
            {ok, {Size, Msg}}
    after
        ?WORKER_REPLY_TIMEOUT ->
            {error, worker_timeout}
    end.

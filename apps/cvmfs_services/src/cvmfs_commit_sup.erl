%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc
%%%
%%% This module implements an OTP supervisor whose children are OTP
%%% gen_servers tasked with serializing the commit operations to each
%%% CVMFS repository.
%%%
%%% The supervisor receives the list of repositories and spawn a
%%% gen_server per repository. It also maintains an ETS table with
%%% the mapping RepoName -> Pid. When a commit request is received,
%%% the Pid of the gen_server, once retrieved from the ETS table, is
%%% bundled with the commit parameters and sent to the gen_server.
%%%
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cvmfs_commit_sup).

-behaviour(supervisor).

-export([start_link/1, init/1, commit/3]).


start_link(Repos) ->
    Sup = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    lists:foreach(fun({RepoName, _RepoKeys}) -> add_manager(RepoName) end,
                  Repos),
    Sup.


init([]) ->
    ets:new(commit_workers, [set, named_table, public]),
    SupervisorSpecs = #{strategy => simple_one_for_one,
                        intensity => 5,
                        period => 5},
    WorkerSpecs = #{ id => cvmfs_commit_worker,
                     start => {cvmfs_commit_worker, start_link, []},
                     restart => transient,
                     shutdown => 2000,
                     type => worker,
                     modules => [cvmfs_commit_worker] },
    {ok, {SupervisorSpecs, [WorkerSpecs]}}.


add_manager(RepoName) ->
    case ets:lookup(commit_workers, RepoName) of
        [] ->
            {ok, Pid} = supervisor:start_child(?MODULE, []),
            ets:insert(commit_workers, {RepoName, Pid}),
            Pid;
        _Pid ->
            {error, exists}
    end.


commit(LeasePath, OldRootHash, NewRootHash) ->
    RepoName = hd(binary:split(LeasePath, <<"/">>)),
    {RepoName, Pid} = hd(ets:lookup(commit_workers, RepoName)),
    cvmfs_commit_worker:commit(Pid, LeasePath, OldRootHash, NewRootHash).


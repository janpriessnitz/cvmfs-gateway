%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc
%%%
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cvmfs_lease_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0
        ,init_per_suite/1, end_per_suite/1
        ,init_per_testcase/2, end_per_testcase/2]).

-export([new_lease/1, new_lease_busy/1, new_lease_expired/1
        ,remove_lease_existing/1, remove_lease_nonexisting/1
        ,check_lease_valid/1, check_lease_expired/1, check_invalid_lease/1
        ,clear_leases/1]).


%% Tests description

all() ->
    [{group, new_leases}
    ,{group, end_leases}
    ,{group, check_leases}].

groups() ->
    [{new_leases, [], [new_lease
                      ,new_lease_busy
                      ,new_lease_expired]}
    ,{end_leases, [], [remove_lease_existing
                      ,remove_lease_nonexisting
                      ,clear_leases]}
    ,{check_leases, [], [check_lease_valid
                        ,check_lease_expired
                        ,check_invalid_lease]}].


%% Set up, tear down

init_per_suite(Config) ->
    application:load(mnesia),
    application:set_env(mnesia, schema_location, ram),
    application:start(mnesia),

    MaxLeaseTime = 50, % milliseconds
    ok = application:load(cvmfs_lease),
    ok = application:set_env(cvmfs_lease, max_lease_time, MaxLeaseTime),
    {ok, _} = application:ensure_all_started(cvmfs_lease),
    lists:flatten([{max_lease_time, MaxLeaseTime}, Config]).

end_per_suite(_Config) ->
    application:stop(cvmfs_lease),
    application:unload(cvmfs_lease),
    application:stop(mnesia),
    application:unload(mnesia),
    ok.

init_per_testcase(_TestCase, Config) ->
    cvmfs_lease:clear_leases(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.


%% Test cases

new_lease(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    [{lease, P, U, Public, Secret, _}] = cvmfs_lease:get_leases().


new_lease_busy(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    {busy, _} = cvmfs_lease:request_lease(U, P, Public, Secret).

new_lease_expired(Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    SleepTime = ?config(max_lease_time, Config) + 10,
    ct:sleep(SleepTime),
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    [{lease, P, U, Public, Secret, _}] = cvmfs_lease:get_leases().

remove_lease_existing(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    ok = cvmfs_lease:end_lease(Public).

remove_lease_nonexisting(_Config) ->
    P = <<"path">>,
    ok = cvmfs_lease:end_lease(P).

clear_leases(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    [{lease, P, U, Public, Secret, _}] = cvmfs_lease:get_leases(),
    ok = cvmfs_lease:clear_leases(),
    [] = cvmfs_lease:get_leases().

check_lease_valid(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    {ok, Secret} = cvmfs_lease:check_lease(Public).

check_lease_expired(_Config) ->
    U = <<"user">>,
    P = <<"path">>,
    Public = <<"public">>,
    Secret = <<"secret">>,
    ok = cvmfs_lease:request_lease(U, P, Public, Secret),
    SleepTime = 1500,
    ct:sleep(SleepTime),
    {error, lease_expired} = cvmfs_lease:check_lease(Public).

check_invalid_lease(_Config) ->
    Public = <<"public">>,
    {error, invalid_lease} = cvmfs_lease:check_lease(Public).

%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2015. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%
-module(ssh_to_openssh_SUITE).

-include_lib("common_test/include/ct.hrl").

%% Note: This directive should only be used in test suites.
-compile(export_all).

-define(TIMEOUT, 50000).
-define(SSH_DEFAULT_PORT, 22).

%%--------------------------------------------------------------------
%% Common Test interface functions -----------------------------------
%%--------------------------------------------------------------------

all() -> 
    case os:find_executable("ssh") of
	false -> 
	    {skip, "openSSH not installed on host"};
	_ ->
	    [{group, erlang_client},
	     {group, erlang_server}
	     ]
    end.

groups() -> 
    [{erlang_client, [], [erlang_shell_client_openssh_server,
			  erlang_client_openssh_server_exec,
			  erlang_client_openssh_server_exec_compressed,
			  erlang_client_openssh_server_setenv,
			  erlang_client_openssh_server_publickey_rsa,
			  erlang_client_openssh_server_publickey_dsa,
			  erlang_client_openssh_server_password,
			  erlang_client_openssh_server_kexs,
			  erlang_client_openssh_server_nonexistent_subsystem
			 ]},
     {erlang_server, [], [erlang_server_openssh_client_exec,
			  erlang_server_openssh_client_exec_compressed,
			  erlang_server_openssh_client_pulic_key_dsa,
			  erlang_server_openssh_client_cipher_suites,
			  erlang_server_openssh_client_macs,
			  erlang_server_openssh_client_kexs]}
    ].

init_per_suite(Config) ->
    catch crypto:stop(),
    case catch crypto:start() of
	ok ->
	    case gen_tcp:connect("localhost", 22, []) of
		{error,econnrefused} ->
		    {skip,"No openssh deamon"};
		_ ->
		    ssh_test_lib:openssh_sanity_check(Config)
	    end;
	_Else ->
	    {skip,"Could not start crypto!"}
    end.

end_per_suite(_Config) ->
    crypto:stop(),
    ok.

init_per_group(erlang_server, Config) ->
    DataDir = ?config(data_dir, Config),
    UserDir = ?config(priv_dir, Config),
    ssh_test_lib:setup_dsa_known_host(DataDir, UserDir),
    Config;
init_per_group(_, Config) ->
    Config.

end_per_group(erlang_server, Config) ->
    UserDir = ?config(priv_dir, Config),
    ssh_test_lib:clean_dsa(UserDir),
    Config;
end_per_group(_, Config) ->
    Config.

init_per_testcase(erlang_server_openssh_client_cipher_suites, Config) ->
    check_ssh_client_support(Config);

init_per_testcase(erlang_server_openssh_client_macs, Config) ->
    check_ssh_client_support(Config);

init_per_testcase(erlang_server_openssh_client_kexs, Config) ->
    check_ssh_client_support(Config);

init_per_testcase(erlang_client_openssh_server_kexs, Config) ->
    check_ssh_client_support(Config);

init_per_testcase(_TestCase, Config) ->
    ssh:start(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ssh:stop(),
    ok.

%%--------------------------------------------------------------------
%% Test Cases --------------------------------------------------------
%%--------------------------------------------------------------------

erlang_shell_client_openssh_server() ->
    [{doc, "Test that ssh:shell/2 works"}].

erlang_shell_client_openssh_server(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    IO = ssh_test_lib:start_io_server(),
    Shell = ssh_test_lib:start_shell(?SSH_DEFAULT_PORT, IO),
    IO ! {input, self(), "echo Hej\n"},
    receive_hej(),
    IO ! {input, self(), "exit\n"},
    receive_logout(),
    receive_normal_exit(Shell).
   
%--------------------------------------------------------------------
erlang_client_openssh_server_exec() ->
    [{doc, "Test api function ssh_connection:exec"}].

erlang_client_openssh_server_exec(Config) when is_list(Config) ->
    ConnectionRef = ssh_test_lib:connect(?SSH_DEFAULT_PORT, [{silently_accept_hosts, true},
							     {user_interaction, false}]),
    {ok, ChannelId0} = ssh_connection:session_channel(ConnectionRef, infinity),
    success = ssh_connection:exec(ConnectionRef, ChannelId0,
				  "echo testing", infinity),
    Data0 = {ssh_cm, ConnectionRef, {data, ChannelId0, 0, <<"testing\n">>}},
    case ssh_test_lib:receive_exec_result(Data0) of
	expected ->
	    ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId0);
	{unexpected_msg,{ssh_cm, ConnectionRef, {exit_status, ChannelId0, 0}}
	 = ExitStatus0} ->
	    ct:log("0: Collected data ~p", [ExitStatus0]),
	    ssh_test_lib:receive_exec_result(Data0,
					     ConnectionRef, ChannelId0);
	Other0 ->
	    ct:fail(Other0)
    end,

    {ok, ChannelId1} = ssh_connection:session_channel(ConnectionRef, infinity),
    success = ssh_connection:exec(ConnectionRef, ChannelId1,
				  "echo testing1", infinity),
    Data1 = {ssh_cm, ConnectionRef, {data, ChannelId1, 0, <<"testing1\n">>}},
    case ssh_test_lib:receive_exec_result(Data1) of
	expected ->
	    ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId1);
	{unexpected_msg,{ssh_cm, ConnectionRef, {exit_status, ChannelId1, 0}}
	 = ExitStatus1} ->
	    ct:log("0: Collected data ~p", [ExitStatus1]),
	    ssh_test_lib:receive_exec_result(Data1,
					     ConnectionRef, ChannelId1);
	Other1 ->
	    ct:fail(Other1)
    end.

%%--------------------------------------------------------------------
erlang_client_openssh_server_exec_compressed() ->
    [{doc, "Test that compression option works"}].

erlang_client_openssh_server_exec_compressed(Config) when is_list(Config) ->
    CompressAlgs = [zlib, 'zlib@openssh.com',none],
    ConnectionRef = ssh_test_lib:connect(?SSH_DEFAULT_PORT, [{silently_accept_hosts, true},
							     {user_interaction, false},
							     {preferred_algorithms,
							      [{compression,CompressAlgs}]}]),
    {ok, ChannelId} = ssh_connection:session_channel(ConnectionRef, infinity),
    success = ssh_connection:exec(ConnectionRef, ChannelId,
				  "echo testing", infinity),
    Data = {ssh_cm, ConnectionRef, {data, ChannelId, 0, <<"testing\n">>}},
    case ssh_test_lib:receive_exec_result(Data) of
	expected ->
	    ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId);
	{unexpected_msg,{ssh_cm, ConnectionRef,
			 {exit_status, ChannelId, 0}} = ExitStatus} ->
	    ct:log("0: Collected data ~p", [ExitStatus]),
	    ssh_test_lib:receive_exec_result(Data,  ConnectionRef, ChannelId);
	Other ->
	    ct:fail(Other)
    end.

%%--------------------------------------------------------------------
erlang_client_openssh_server_kexs() ->
    [{doc, "Test that we can connect with different KEXs."}].

erlang_client_openssh_server_kexs(Config) when is_list(Config) ->
    Success =
	lists:foldl(
	  fun(Kex, Acc) ->
		  ConnectionRef = 
		      ssh_test_lib:connect(?SSH_DEFAULT_PORT, [{silently_accept_hosts, true},
							       {user_interaction, false},
							       {preferred_algorithms,
								[{kex,[Kex]}]}]),
    
		  {ok, ChannelId} =
		      ssh_connection:session_channel(ConnectionRef, infinity),
		  success =
		      ssh_connection:exec(ConnectionRef, ChannelId,
					  "echo testing", infinity),

		  ExpectedData = {ssh_cm, ConnectionRef, {data, ChannelId, 0, <<"testing\n">>}},
		  case ssh_test_lib:receive_exec_result(ExpectedData) of
		      expected ->
			  ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId),
			  Acc;
		      {unexpected_msg,{ssh_cm, ConnectionRef,
				       {exit_status, ChannelId, 0}} = ExitStatus} ->
			  ct:log("0: Collected data ~p", [ExitStatus]),
			  ssh_test_lib:receive_exec_result(ExpectedData,  ConnectionRef, ChannelId),
			  Acc;
		      Other ->
			  ct:log("~p failed: ~p",[Kex,Other]),
			  false
		  end
	  end, true, ssh_transport:supported_algorithms(kex)),
    case Success of
	true ->
	    ok;
	false ->
	    {fail, "Kex failed for one or more algos"}
    end.

%%--------------------------------------------------------------------
erlang_server_openssh_client_exec() ->
    [{doc, "Test that exec command works."}].

erlang_server_openssh_client_exec(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
					     {failfun, fun ssh_test_lib:failfun/2}]),
    

    ct:sleep(500),

    Cmd = "ssh -p " ++ integer_to_list(Port) ++
	" -o UserKnownHostsFile=" ++ KnownHosts ++ " " ++ Host ++ " 1+1.",

    ct:log("Cmd: ~p~n", [Cmd]),

    SshPort = open_port({spawn, Cmd}, [binary]),

    receive
        {SshPort,{data, <<"2\n">>}} ->
	    ok
    after ?TIMEOUT ->
	    ct:fail("Did not receive answer")

    end,
     ssh:stop_daemon(Pid).

%%--------------------------------------------------------------------
erlang_server_openssh_client_cipher_suites() ->
    [{doc, "Test that we can connect with different cipher suites."}].

erlang_server_openssh_client_cipher_suites(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
					     {failfun, fun ssh_test_lib:failfun/2}]),


    ct:sleep(500),

    Supports = crypto:supports(),
    Ciphers = proplists:get_value(ciphers, Supports),
    Tests = [
        {"3des-cbc", lists:member(des3_cbc, Ciphers)},
        {"aes128-cbc", lists:member(aes_cbc128, Ciphers)},
        {"aes128-ctr", lists:member(aes_ctr, Ciphers)},
        {"aes256-cbc", false}
    ],
    lists:foreach(fun({Cipher, Expect}) ->
        Cmd = "ssh -p " ++ integer_to_list(Port) ++
        " -o UserKnownHostsFile=" ++ KnownHosts ++ " " ++ Host ++ " " ++
        " -c " ++ Cipher ++ " 1+1.",

        ct:log("Cmd: ~p~n", [Cmd]),

        SshPort = open_port({spawn, Cmd}, [binary, stderr_to_stdout]),

        case Expect of
            true ->
                receive
                    {SshPort,{data, <<"2\n">>}} ->
                       ok
                after ?TIMEOUT ->
                    ct:fail("Did not receive answer")
                end;
            false ->
                receive
                    {SshPort,{data, <<"no matching cipher found", _/binary>>}} ->
                        ok
                after ?TIMEOUT ->
                    ct:fail("Did not receive no matching cipher message")
                end
        end
    end, Tests),

     ssh:stop_daemon(Pid).

%%--------------------------------------------------------------------
erlang_server_openssh_client_macs() ->
    [{doc, "Test that we can connect with different MACs."}].

erlang_server_openssh_client_macs(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
                         {failfun, fun ssh_test_lib:failfun/2}]),


    ct:sleep(500),

    Supports = crypto:supports(),
    Hashs = proplists:get_value(hashs, Supports),
    MACs = [{"hmac-sha1", lists:member(sha, Hashs)},
        {"hmac-sha2-256", lists:member(sha256, Hashs)},
        {"hmac-md5-96", false},
        {"hmac-ripemd160", false}],
    lists:foreach(fun({MAC, Expect}) ->
        Cmd = "ssh -p " ++ integer_to_list(Port) ++
        " -o UserKnownHostsFile=" ++ KnownHosts ++ " " ++ Host ++ " " ++
        " -o MACs=" ++ MAC ++ " 1+1.",

        ct:log("Cmd: ~p~n", [Cmd]),

        SshPort = open_port({spawn, Cmd}, [binary, stderr_to_stdout]),

        case Expect of
            true ->
                receive
                    {SshPort,{data, <<"2\n">>}} ->
                       ok
                after ?TIMEOUT ->
                    ct:fail("Did not receive answer")
                end;
            false ->
                receive
                    {SshPort,{data, <<"no matching mac found", _/binary>>}} ->
                        ok
                after ?TIMEOUT ->
                    ct:fail("Did not receive no matching mac message")
                end
        end
    end, MACs),

     ssh:stop_daemon(Pid).

%%--------------------------------------------------------------------
erlang_server_openssh_client_kexs() ->
    [{doc, "Test that we can connect with different KEXs."}].

erlang_server_openssh_client_kexs(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
					     {failfun, fun ssh_test_lib:failfun/2},
					     {preferred_algorithms,
					      [{kex,ssh_transport:supported_algorithms(kex)}]}
					    ]),
    ct:sleep(500),

    ErlKexs = lists:map(fun erlang:atom_to_list/1, 
			ssh_transport:supported_algorithms(kex)),
    OpenSshKexs = string:tokens(os:cmd("ssh -Q kex"), "\n"),
    
    Kexs = [{OpenSshKex,lists:member(OpenSshKex,ErlKexs)} 
	    || OpenSshKex <- OpenSshKexs],

    Success =
	lists:foldl(
	  fun({Kex, Expect}, Acc) ->
		  Cmd = "ssh -p " ++ integer_to_list(Port) ++
		      " -o UserKnownHostsFile=" ++ KnownHosts ++ " " ++ Host ++ " " ++
		      " -o KexAlgorithms=" ++ Kex ++ " 1+1.",

		  ct:log("Cmd: ~p~n", [Cmd]),

		  SshPort = open_port({spawn, Cmd}, [binary, stderr_to_stdout]),

		  case Expect of
		      true ->
			  receive
			      {SshPort,{data, <<"2\n">>}} ->
				  Acc
			  after ?TIMEOUT ->
				  ct:log("Did not receive answer for ~p",[Kex]),
				  false
			  end;
		      false ->
			  receive
			      {SshPort,{data, <<"Unable to negotiate a key exchange method", _/binary>>}} ->
				  Acc
			  after ?TIMEOUT ->
				  ct:log("Did not receive no matching kex message for ~p",[Kex]),
				  false
			  end
		  end
	  end, true, Kexs),
    
    ssh:stop_daemon(Pid),

    case Success of
	true ->
	    ok;
	false ->
	    {fail, "Kex failed for one or more algos"}
    end.
	

%%--------------------------------------------------------------------
erlang_server_openssh_client_exec_compressed() ->
    [{doc, "Test that exec command works."}].

erlang_server_openssh_client_exec_compressed(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

%%    CompressAlgs = [zlib, 'zlib@openssh.com'], % Does not work
    CompressAlgs = [zlib],
    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
					     {preferred_algorithms,
					      [{compression, CompressAlgs}]},
					     {failfun, fun ssh_test_lib:failfun/2}]),

    ct:sleep(500),

    Cmd = "ssh -p " ++ integer_to_list(Port) ++
	" -o UserKnownHostsFile=" ++ KnownHosts ++ " -C "++ Host ++ " 1+1.",
    SshPort = open_port({spawn, Cmd}, [binary]),

    receive
        {SshPort,{data, <<"2\n">>}} ->
	    ok
    after ?TIMEOUT ->
	    ct:fail("Did not receive answer")

    end,
    ssh:stop_daemon(Pid).

%%--------------------------------------------------------------------
erlang_client_openssh_server_setenv() ->
    [{doc, "Test api function ssh_connection:setenv"}].

erlang_client_openssh_server_setenv(Config) when is_list(Config) ->
    ConnectionRef =
	ssh_test_lib:connect(?SSH_DEFAULT_PORT, [{silently_accept_hosts, true},
						 {user_interaction, false}]),
    {ok, ChannelId} =
	ssh_connection:session_channel(ConnectionRef, infinity),
    Env = case ssh_connection:setenv(ConnectionRef, ChannelId,
				     "ENV_TEST", "testing_setenv",
				     infinity) of
	      success ->
		  <<"tesing_setenv\n">>;
	      failure ->
		  <<"\n">>
	  end,
    success = ssh_connection:exec(ConnectionRef, ChannelId,
				  "echo $ENV_TEST", infinity),
    Data = {ssh_cm, ConnectionRef, {data, ChannelId, 0, Env}},
    case ssh_test_lib:receive_exec_result(Data) of
	expected ->
	    ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId);
	{unexpected_msg,{ssh_cm, ConnectionRef,
			 {data,0,1, UnxpectedData}}} ->
	    %% Some os may return things as
	    %% ENV_TEST: Undefined variable.\n"
	    ct:log("UnxpectedData: ~p", [UnxpectedData]),
	    ssh_test_lib:receive_exec_end(ConnectionRef, ChannelId);
	{unexpected_msg,{ssh_cm, ConnectionRef, {exit_status, ChannelId, 0}}
	 = ExitStatus} ->
	    ct:log("0: Collected data ~p", [ExitStatus]),
	    ssh_test_lib:receive_exec_result(Data,
					     ConnectionRef, ChannelId);
	Other ->
	    ct:fail(Other)
    end.

%%--------------------------------------------------------------------

%% setenv not meaningfull on erlang ssh daemon!

%%--------------------------------------------------------------------
erlang_client_openssh_server_publickey_rsa() ->
    [{doc, "Validate using rsa publickey."}].
erlang_client_openssh_server_publickey_rsa(Config) when is_list(Config) ->
    {ok,[[Home]]} = init:get_argument(home),
    KeyFile =  filename:join(Home, ".ssh/id_rsa"),
    case file:read_file(KeyFile) of
	{ok, Pem} ->
	    case public_key:pem_decode(Pem) of
		[{_,_, not_encrypted}] ->
		    ConnectionRef =
			ssh_test_lib:connect(?SSH_DEFAULT_PORT,
					     [{public_key_alg, ssh_rsa},
					      {user_interaction, false},
					      silently_accept_hosts]),
		    {ok, Channel} =
			ssh_connection:session_channel(ConnectionRef, infinity),
		    ok = ssh_connection:close(ConnectionRef, Channel),
		    ok = ssh:close(ConnectionRef);
		_ ->
		    {skip, {error, "Has pass phrase can not be used by automated test case"}} 
	    end;
	_ ->
	    {skip, "no ~/.ssh/id_rsa"}  
    end.
	

%%--------------------------------------------------------------------
erlang_client_openssh_server_publickey_dsa() ->
    [{doc, "Validate using dsa publickey."}].
erlang_client_openssh_server_publickey_dsa(Config) when is_list(Config) ->
    {ok,[[Home]]} = init:get_argument(home),
    KeyFile =  filename:join(Home, ".ssh/id_dsa"),
    case file:read_file(KeyFile) of
	{ok, Pem} ->
	    case public_key:pem_decode(Pem) of
		[{_,_, not_encrypted}] ->
		    ConnectionRef =
			ssh_test_lib:connect(?SSH_DEFAULT_PORT,
					     [{public_key_alg, ssh_dsa},
					      {user_interaction, false},
					      silently_accept_hosts]),
		    {ok, Channel} =
			ssh_connection:session_channel(ConnectionRef, infinity),
		    ok = ssh_connection:close(ConnectionRef, Channel),
		    ok = ssh:close(ConnectionRef);
		_ ->
		    {skip, {error, "Has pass phrase can not be used by automated test case"}} 
	    end;
	_ ->
	    {skip, "no ~/.ssh/id_dsa"}  
    end.
%%--------------------------------------------------------------------
erlang_server_openssh_client_pulic_key_dsa() ->
    [{doc, "Validate using dsa publickey."}].
erlang_server_openssh_client_pulic_key_dsa(Config) when is_list(Config) ->
    SystemDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    KnownHosts = filename:join(PrivDir, "known_hosts"),

    {Pid, Host, Port} = ssh_test_lib:daemon([{system_dir, SystemDir},
					     {public_key_alg, ssh_dsa},
					     {failfun, fun ssh_test_lib:failfun/2}]),
    
    ct:sleep(500),

    Cmd = "ssh -p " ++ integer_to_list(Port) ++
	" -o UserKnownHostsFile=" ++ KnownHosts ++
	" " ++ Host ++ " 1+1.",
    SshPort = open_port({spawn, Cmd}, [binary]),

    receive
        {SshPort,{data, <<"2\n">>}} ->
	    ok
    after ?TIMEOUT ->
	    ct:fail("Did not receive answer")
    end,
     ssh:stop_daemon(Pid).

%%--------------------------------------------------------------------
erlang_client_openssh_server_password() ->
    [{doc, "Test client password option"}].
erlang_client_openssh_server_password(Config) when is_list(Config) ->
    %% to make sure we don't public-key-auth
    UserDir = ?config(data_dir, Config),
    {error, Reason0} =
	ssh:connect(any, ?SSH_DEFAULT_PORT, [{silently_accept_hosts, true},
						 {user, "foo"},
						 {password, "morot"},
						 {user_interaction, false},
						 {user_dir, UserDir}]),
    
    ct:log("Test of user foo that does not exist. "
		       "Error msg: ~p~n", [Reason0]),

    User = string:strip(os:cmd("whoami"), right, $\n),

    case length(string:tokens(User, " ")) of
	1 ->
	    {error, Reason1} =
		ssh:connect(any, ?SSH_DEFAULT_PORT,
			    [{silently_accept_hosts, true},
			     {user, User},
			     {password, "foo"},
			     {user_interaction, false},
			     {user_dir, UserDir}]),
	    ct:log("Test of wrong Pasword.  "
			       "Error msg: ~p~n", [Reason1]);
	_ ->
	    ct:log("Whoami failed reason: ~n", [])
	end.

%%--------------------------------------------------------------------

erlang_client_openssh_server_nonexistent_subsystem() ->
    [{doc, "Test client password option"}].
erlang_client_openssh_server_nonexistent_subsystem(Config) when is_list(Config) ->

    ConnectionRef = ssh_test_lib:connect(?SSH_DEFAULT_PORT,
					 [{user_interaction, false},
					  silently_accept_hosts]),

    {ok, ChannelId} = ssh_connection:session_channel(ConnectionRef, infinity),

    failure = ssh_connection:subsystem(ConnectionRef, ChannelId, "foo", infinity).

%%--------------------------------------------------------------------
%
%% Not possible to send password with openssh without user interaction
%%
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%%% Internal functions -----------------------------------------------
%%--------------------------------------------------------------------
receive_hej() ->
    receive
	<<"Hej", _binary>> = Hej ->
	    ct:log("Expected result: ~p~n", [Hej]);
	<<"Hej\n", _binary>> = Hej ->
	    ct:log("Expected result: ~p~n", [Hej]);
	<<"Hej\r\n", _/binary>> = Hej ->
	    ct:log("Expected result: ~p~n", [Hej]);
	Info ->
	    Lines = binary:split(Info, [<<"\r\n">>], [global]),
	    case lists:member(<<"Hej">>, Lines) of
		true ->
		    ct:log("Expected result found in lines: ~p~n", [Lines]),
		    ok;
		false ->
		    ct:log("Extra info: ~p~n", [Info]),
		    receive_hej()
	    end
    end.

receive_logout() ->
    receive
	<<"logout">> ->
	    extra_logout(),
	    receive
		<<"Connection closed">> ->
		    ok
	    end;
	Info ->
	    ct:log("Extra info when logging out: ~p~n", [Info]),
	    receive_logout()
	end.

receive_normal_exit(Shell) ->
    receive
	{'EXIT', Shell, normal} ->
	    ok;
	<<"\r\n">> ->
	    receive_normal_exit(Shell);
	Other ->
	    ct:fail({unexpected_msg, Other})
    end.

extra_logout() ->
    receive 	
	<<"logout">> ->
	    ok
    after 500 -> 
	    ok
    end.

%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% Check if we have a "newer" ssh client that supports these test cases
%%--------------------------------------------------------------------
check_ssh_client_support(Config) ->
    Port = open_port({spawn, "ssh -Q cipher"}, [exit_status, stderr_to_stdout]),
    case check_ssh_client_support2(Port) of
	0 -> % exit status from command (0 == ok)
	    ssh:start(),
	    Config;
	_ ->
	    {skip, "test case not supported by ssh client"}
    end.

check_ssh_client_support2(P) ->
    receive
	{P, {data, _A}} ->
	    check_ssh_client_support2(P);
	{P, {exit_status, E}} ->
	    E
    after 5000 ->
	    ct:log("Openssh command timed out ~n"),
	    -1
    end.

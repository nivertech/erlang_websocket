%% 
%% Basic implementation of the WebSocket API:
%% http://dev.w3.org/html5/websockets/
%% However, it's not completely compliant with the WebSocket spec.
%% Specifically it doesn't handle the case where 'length' is included
%% in the TCP packet, SSL is not supported, and you don't pass a 'ws://type url to it.
%%
%% It also defines a behaviour to implement for client implementations.
%% @author Dave Bryson [http://weblog.miceda.org]
%%
-module(websocket_client).

-behaviour(gen_server).

%% API
-export([start/3,write/1,close/0,initial_request/2,initial_request/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% Ready States
-define(CONNECTING,0).
-define(OPEN,1).
-define(CLOSED,2).

%% Behaviour definition
-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{onmessage,2},{onopen,1},{onclose,1},{oninfo,2},{oncast,2}];
behaviour_info(_) ->
    undefined.

-record(state, {socket,
                readystate=undefined,
                headers=[],
                callback,
                client_state}).

start(Host,Port,Mod) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{Host,Port,Mod}], []).

init(Args) ->
    process_flag(trap_exit,true),
    [{Host,Port,Mod}] = Args,
    {ok, Sock} = gen_tcp:connect(Host,Port,[binary,{packet, 0},{active,true}]),
    
    %% Hardcoded path for now...
    Req = initial_request(Host,"/"),
    ok = gen_tcp:send(Sock,Req),
    inet:setopts(Sock, [{packet, http}]),
    
    {ok,#state{socket=Sock,callback=Mod}}.

%% Write to the server
write(Data) ->
    gen_server:cast(?MODULE,{send,Data}).

%% Close the socket
close() ->
    gen_server:cast(?MODULE,close).

handle_cast({send,Data}, State) ->
    gen_tcp:send(State#state.socket,iolist_to_binary([0,Data,255])),
    {noreply, State};

handle_cast(close,State) ->
    Mod = State#state.callback,
    {_Resp, ClientState1} = Mod:onclose(State#state.client_state),
    gen_tcp:close(State#state.socket),
    State1 = State#state{readystate=?CLOSED,client_state=ClientState1},
    {stop,normal,State1};

handle_cast(Unknown,State) ->
    % io:format("websocket_client: Redirecting unknown cast ~p~n", [Unknown]),
    Mod = State#state.callback,
    {Resp, ClientState1} = Mod:oncast(Unknown, State#state.client_state),
    {Resp, State#state{client_state=ClientState1}}.

%% Start handshake
handle_info({http,Socket,{http_response,{1,1},101,"Web Socket Protocol Handshake"}}, State) ->
    State1 = State#state{readystate=?CONNECTING,socket=Socket},
    {noreply, State1};

%% Extract the headers
handle_info({http,Socket,{http_header, _, Name, _, Value}},State) ->
    case State#state.readystate of
	?CONNECTING ->
	    H = [{Name,Value} | State#state.headers],
	    State1 = State#state{headers=H,socket=Socket},
	    {noreply,State1};
	undefined ->
	    %% Bad state should have received response first
	    {stop,error,State}
    end;

%% Once we have all the headers check for the 'Upgrade' flag 
handle_info({http,Socket,http_eoh},State) ->
    %% Validate headers, set state, change packet type back to raw
     case State#state.readystate of
	?CONNECTING ->
	     Headers = State#state.headers,
	     case proplists:get_value('Upgrade',Headers) of
		 "WebSocket" ->
		     inet:setopts(Socket, [{packet, raw}]),
		     State1 = State#state{socket=Socket},
		     Mod = State#state.callback,
             {Resp, ClientState1} = Mod:onopen(State1#state.client_state),
		     {Resp, State1#state{client_state=ClientState1}};
		 _Any  ->
		     {stop,error,State}
	     end;
	undefined ->
	    %% Bad state should have received response first
	    {stop,error,State}
    end;

%% Handshake complete, handle packets
handle_info({tcp, Socket, Data},State) ->
    % io:format("handle_info({tcp, ~p, ~p}, ~p)~n", [Socket, Data, State]),
    case State#state.readystate of
	?OPEN ->
        % io:format("Will call unframe with Data = ~p~n", [Data]),
	    D = unframe(binary_to_list(Data)),
	    Mod = State#state.callback,	    
        {Resp, ClientState1} = Mod:onmessage(D, State#state.client_state),
	    {Resp, State#state{client_state=ClientState1}};
    ?CONNECTING ->
        <<_:16/bytes,Rest/bytes>> = Data,
        case Rest of 
        <<>> -> {noreply, State#state{readystate=?OPEN}};
        _  -> handle_info({tcp, Socket, Rest}, State#state{readystate=?OPEN})
        end;
	_Any ->
	    {stop,error,State}
    end;

handle_info({tcp_closed, _Socket},State) ->
    Mod = State#state.callback,
    {_Resp, ClientState1} = Mod:onclose(State#state.client_state),
    {stop,normal,State#state{client_state=ClientState1}};

handle_info({tcp_error, _Socket, _Reason},State) ->
    {stop,tcp_error,State};

handle_info({'EXIT', _Pid, _Reason},State) ->
    {noreply,State};

handle_info(Unknown, State) ->
    Mod = State#state.callback,
    {Resp, ClientState1} = Mod:oninfo(Unknown, State#state.client_state),
    {Resp, State#state{client_state=ClientState1}}.

handle_call(_Request,_From,State) ->
    {reply,ok,State}.

terminate(Reason, _State) ->
    error_logger:info_msg("Terminated ~p~n",[Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

initial_request(Host,Path) ->
    initial_request(Host, Path, undefined).

initial_request(Host,Path,Cookie) ->
    CookieString = case Cookie of undefined -> "" ; _ -> "Cookie: " ++ Cookie ++ "\r\n" end,
    "GET "++ Path ++" HTTP/1.1\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n" ++ 
	"Host: " ++ Host ++ "\r\n" ++
	"Origin: http://" ++ Host ++ "\r\n" ++
    "Sec-WebSocket-Key1: 4y n D9118J  7 9Z 2      4\r\n" ++
    "Sec-WebSocket-Key2: 1487^9  C9201V2\r\n\r\n" ++
    CookieString ++
    [16#cb, 16#15, 16#88, 16#c8, 
     16#91, 16#15, 16#e1, 16#92].

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


unframe(_Param=[0|T]) -> 
    % io:format("unframe(~p)~n", [Param]),
    unframe1(T).
unframe1([255]) -> 
    % io:format("unframe1([255])~n"),
    [];
unframe1(_Param=[H|T]) -> 
    % io:format("unframe1(~p)~n", [Param]),
    [H|unframe1(T)].

    

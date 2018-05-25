import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';

class Mattermost {
  String _username;
  String _teamName;

  _RestGateway _restGateway;
  _SocketGateway _socketGateway;

  PostCallback _postCallback;

  String _teamId;
  String _ownUserId;
  Map<String, String> _channelMap = new Map();

  factory Mattermost.withCredentials(bool secureSocket, String url,
      String username, String password, String teamName) {
    return new Mattermost._internal(
        secureSocket, url, username, password, null, teamName);
  }

  factory Mattermost.withToken(
      bool secureSocket, String url, String username, String accessToken, String teamName) {
    return new Mattermost._internal(
        secureSocket, url, username, null, accessToken, teamName);
  }

  Mattermost._internal(bool secureSocket, String url, this._username,
      String password, String accessToken, this._teamName) {
    _restGateway =
        new _RestGateway(secureSocket, url, _username, password, accessToken);
    _socketGateway =
        new _SocketGateway(secureSocket, url, (event) => _handleEvent(event));
  }

  listen(postCallback) async {
    _postCallback = postCallback;

    // Login and get token
    var accessToken = await _restGateway.getAccessToken();

    // Start listening to commands
    _socketGateway.connect(accessToken);
  }

  disconnect() {
    _socketGateway.disconnect();
  }

  post(String channelId, String message) async {
    _restGateway.post("/posts", {"channel_id": channelId, "message": message});
  }

  postToChannel(String channelName, String message) async {
    var channelId = await getChannelId(channelName);
    post(channelId, message);
  }

  postDirectMessage(String username, String message) async {
    var userId = await getUserId(username);
    var channelId = await getDirectChannelId(userId);
    post(channelId, message);
  }

  Future<String> getTeamId() async {
    if (_teamId == null) {
      _teamId = (await _restGateway.get("/teams/name/$_teamName"))["id"];
    }
    return _teamId;
  }

  Future<String> getOwnUserId() async {
    if (_ownUserId == null) {
      _ownUserId = await getUserId(_username);
    }
    return _ownUserId;
  }

  Future<String> getChannelId(String channelName) async {
    // Cache channel id
    if (!_channelMap.containsKey(channelName)) {
      String channelId = (await _restGateway
          .get("/teams/$_teamId/channels/name/$channelName"))["id"];
      _channelMap[channelName] = channelId;
    }
    return _channelMap[channelName];
  }

  Future<String> getDirectChannelId(String userId) async {
    var ownId = await getOwnUserId();
    return (await _restGateway
        .post("/channels/direct", [ownId, userId]))["id"];
  }

  Future<String> getUserId(String username) async {
    return (await _restGateway.get("/users/username/$username"))["id"];
  }

  notifyTyping(String channelId) {
    _socketGateway.send("user_typing", {"channel_id": channelId});
  }

  _handleEvent(var event) {
    print("<-- $event\n");

    var type = event["event"];
    switch (type) {
      case "posted":
        var sender = event["data"]["sender_name"];
        if (sender != _username) {
          var channelType = event["data"]["channel_type"];
          var post = json.decode(event["data"]["post"]);
          String message = post["message"];
          if (message.contains("@$_username") || channelType == "D") {
            _postCallback(sender, post["channel_id"], message);
          }
        }
        break;
    }
  }
}

class _RestGateway {
  final _endpoint;
  String _username, _password;
  String _accessToken;

  _RestGateway(bool secureSocket, String url, this._username, this._password,
      this._accessToken)
      : _endpoint = (secureSocket ? "https" : "http") + "://$url/api/v4";

  Future<String> getAccessToken() async {
    if (_accessToken == null) {
      var endpoint = _endpoint + "/users/login";
      var body = {"login_id": _username, "password": _password};
      print("--> POST $endpoint");
      print("    ${body.toString().replaceAll(_password, "******")}");

      var response = await http.post(endpoint, body: json.encode(body));
      var map = json.decode(response.body);
      print("<-- $map");
      _accessToken = response.headers["token"];
    }
    return _accessToken;
  }

  get(String path) async {
    await getAccessToken();

    var endpoint = _endpoint + path;
    print("--> GET $endpoint");

    var response = await http
        .get(endpoint, headers: {"Authorization": "Bearer $_accessToken"});
    print("<-- ${response.statusCode} ${response.body}\n");
    return json.decode(response.body);
  }

  post(String path, dynamic body) async {
    await getAccessToken();

    var endpoint = _endpoint + path;
    print("--> POST $endpoint");
    print("    ${json.encode(body)}");

    var response = await http.post(endpoint,
        headers: {"Authorization": "Bearer $_accessToken"},
        body: json.encode(body));
    print("Response status: ${response.statusCode}");
    print("Response body: ${response.body}\n");
    return json.decode(response.body);
  }
}

class _SocketGateway {
  final _endpoint;
  final _EventCallback _callback;
  var _seq = 0;

  _SocketGateway(bool secureSocket, String url, this._callback)
      : _endpoint = (secureSocket ? "wss" : "ws") + "://$url/api/v4/websocket";

  WebSocket _socket;
  connect(var token) async {
    print("Connecting...");
    _socket = await WebSocket.connect(_endpoint);
    _socket.pingInterval = new Duration(seconds: 5);
    print("Connected");

    // Authenticate the socket connection
    send("authentication_challenge", {"token": token});

    // Start listening to events
    _socket.listen(
      (event) {
        var map = json.decode(event);
        if (map.containsKey("seq")) {
          _seq = map["seq"];
        }
        _callback(map);
      },
      onDone: () => print("Done"),
      onError: (error) => print(error),
      cancelOnError: false,
    );
  }

  send(String action, Map data) {
    var payload = {"seq": _seq + 1, "action": action, "data": data};
    print("--> $payload");
    _socket.add(json.encode(payload));
  }

  disconnect() {
    _socket.close();
  }
}

typedef void _EventCallback(Map event);

typedef void PostCallback(String sender, String channelId, String message);
